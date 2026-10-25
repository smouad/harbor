// Licensed under GPL-3.0. See LICENSE.
//
//  ACPClient.swift
//  Harbor
//
//  An agent installed on the Mac (Claude, Codex) spoken to over the Agent Client Protocol:
//  JSON-RPC 2.0, one message per line, over the agent process's stdio. The agent runs its own
//  model and tool loop with the CLI's own sign-in; Harbor sends prompts, shows the streamed
//  reply and answers the agent's permission requests. https://agentclientprotocol.com
//

import Foundation
import HarborSettings
import OSLog

@MainActor
final class ACPClient {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Harbor", category: "ACP")

    /// The agents Harbor knows how to start. Each is the agent's own ACP adapter, fetched and run
    /// by bunx (or npx) from the person's PATH, so nothing is bundled and updates come for free.
    struct Preset {
        let type: AIProviderType
        let package: String
        /// The agent's own CLI, whose presence on PATH means it is installed (and holds the sign-in).
        let cli: String
        /// What to run in Terminal when the agent answers that it is not signed in.
        let signIn: String

        var providerId: String { type.rawValue }
        var modelId: String { type.rawValue + ".default" }

        static let all: [Preset] = [
            Preset(type: .claudeACP, package: "@agentclientprotocol/claude-agent-acp", cli: "claude", signIn: "claude /login"),
            Preset(type: .codexACP, package: "@agentclientprotocol/codex-acp", cli: "codex", signIn: "codex login"),
        ]

        static func of(_ type: AIProviderType) -> Preset? { all.first { $0.type == type } }

        /// The agents whose CLI is on the person's PATH, in `all`'s order.
        static func installed() async -> [Preset] {
            let directories = await Launcher.loginShellPath().split(separator: ":").map(String.init)
            return all.filter { preset in
                directories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/\(preset.cli)") }
            }
        }
    }

    enum ACPError: LocalizedError {
        case launcherMissing
        case exited
        case agent(String)

        var errorDescription: String? {
            switch self {
            case .launcherMissing:
                return "Neither bunx nor npx was found on your PATH. Install Bun (bun.sh) or Node.js to use Claude and Codex."
            case .exited:
                return "The agent stopped. Check that it is installed and signed in, then start a new chat."
            case .agent(let message):
                return message
            }
        }
    }

    /// Callbacks into the chat, all on the main actor.
    struct Events {
        /// The whole reply so far, each time a piece arrives.
        var onText: (String) -> Void
        /// The tool the agent is running now, nil once it finishes.
        var onTool: (String?) -> Void
        /// A permission request: the tool's title, its input, whether it is one of the browser's own
        /// tools (an MCP tool; the only MCP server an agent gets is Harbor's), and the agent's options.
        /// Returns the chosen option's id, or nil to cancel.
        var onPermission: (_ title: String, _ input: [String: Any], _ browserTool: Bool, _ options: [[String: Any]]) async -> String?
        /// The session's options changed (the agent switched model, or answered a change).
        var onOptions: ([ConfigOption]) -> Void
    }

    /// A setting the agent offers for its session, such as the model or the reasoning effort.
    /// Category is ACP's: "model", "thought_level", "mode"…
    struct ConfigOption: Codable, Equatable, Identifiable {
        struct Choice: Codable, Equatable, Identifiable {
            let value: String
            let name: String
            var id: String { value }
        }
        let id: String
        let name: String
        let category: String?
        var currentValue: String
        let choices: [Choice]

        var currentName: String { choices.first { $0.value == currentValue }?.name ?? currentValue }

        static func parse(_ list: Any?) -> [ConfigOption] {
            (list as? [[String: Any]] ?? []).compactMap { raw in
                guard let id = raw["id"] as? String, let current = raw["currentValue"] as? String else { return nil }
                let choices = (raw["options"] as? [[String: Any]] ?? []).compactMap { option -> Choice? in
                    guard let value = option["value"] as? String else { return nil }
                    return Choice(value: value, name: option["name"] as? String ?? value)
                }
                guard !choices.isEmpty else { return nil }
                return ConfigOption(id: id, name: raw["name"] as? String ?? id, category: raw["category"] as? String,
                                    currentValue: current, choices: choices)
            }
        }
    }

    /// A JSON object crossing a continuation. The values are plain JSON, never shared mutably.
    private struct JSONObject: @unchecked Sendable { let value: [String: Any] }

    let preset: Preset
    var events: Events?
    private let transport: StdioTransport
    private var nextId = 0
    private var pending: [Int: CheckedContinuation<JSONObject, Error>] = [:]
    private var receiveTask: Task<Void, Never>?
    private var sessionId: String?
    private var reply = ""
    /// Tool call titles by id: Codex's permission requests carry only the id.
    private var toolTitles: [String: String] = [:]
    /// The session's options, as the agent last reported them.
    private(set) var options: [ConfigOption] = []
    /// Whether the agent takes a system prompt in `session/new`; if not, instructions go with the first message.
    private(set) var takesSystemPrompt = false

    private init(preset: Preset, transport: StdioTransport) {
        self.preset = preset
        self.transport = transport
    }

    // MARK: - Lifecycle

    /// Starts the agent and completes the ACP handshake.
    static func launch(_ preset: Preset) async throws -> ACPClient {
        let launcher = try await Launcher.resolve()
        let transport = StdioTransport(
            command: launcher.command,
            args: launcher.args + [preset.package],
            envVars: ["PATH": launcher.path]
        )
        try transport.start()
        let client = ACPClient(preset: preset, transport: transport)
        client.startReceiving()
        let initialized = try await client.request("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "Harbor", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"],
        ])
        let capabilities = initialized["agentCapabilities"] as? [String: Any]
        client.takesSystemPrompt = (capabilities?["sessionCapabilities"] as? [String: Any])?["systemPrompt"] != nil
        return client
    }

    /// Opens the session this chat uses. `mcpServers` are ACP server descriptions, given to the
    /// agent as tools it can call itself; `systemPrompt` is appended to the agent's own when it takes one.
    func newSession(cwd: URL, mcpServers: [[String: Any]], systemPrompt: String) async throws {
        var params: [String: Any] = ["cwd": cwd.path, "mcpServers": mcpServers]
        if takesSystemPrompt {
            params["systemPrompt"] = ["mode": "append", "content": [["type": "text", "text": systemPrompt]]]
        }
        if preset.type == .claudeACP {
            // A browser assistant, not a coding session: none of the person's Claude Code settings,
            // plugins, skills or MCP servers. Loading them made every first reply ~5 s slower.
            params["_meta"] = ["claudeCode": ["options": ["settingSources": [String](), "strictMcpConfig": true, "promptSuggestions": false]]]
        }
        let result = try await request("session/new", params)
        guard let id = result["sessionId"] as? String else { throw ACPError.agent("The agent did not open a session.") }
        sessionId = id
        options = ConfigOption.parse(result["configOptions"])
    }

    /// Changes one of the session's options (model, effort…) and keeps the agent's answer.
    func setOption(_ id: String, to value: String) async throws {
        guard let sessionId else { throw ACPError.agent("No session.") }
        let result = try await request("session/set_config_option", ["sessionId": sessionId, "configId": id, "value": value])
        let updated = ConfigOption.parse(result["configOptions"])
        if !updated.isEmpty { options = updated }
    }

    var hasSession: Bool { sessionId != nil }

    /// Sends one turn and returns the agent's whole reply once it ends the turn.
    func prompt(_ text: String) async throws -> String {
        guard let sessionId else { throw ACPError.agent("No session.") }
        reply = ""
        let result = try await request("session/prompt", [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]],
        ])
        if let reason = result["stopReason"] as? String, reason == "refusal", reply.isEmpty {
            return "The agent declined to answer."
        }
        return reply
    }

    /// Asks the agent to stop the turn in progress; `prompt` then returns with what it had.
    func cancel() {
        guard let sessionId else { return }
        notify("session/cancel", ["sessionId": sessionId])
    }

    func close() {
        receiveTask?.cancel()
        receiveTask = nil
        failPending(ACPError.exited)
        let transport = transport
        Task { await transport.close() }
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        nextId += 1
        let id = nextId
        let object = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONObject, Error>) in
            pending[id] = continuation
            write(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }
        return object.value
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        write(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func respond(to id: Any, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func write(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        let transport = transport
        Task {
            do { try await transport.send(data) } catch { Self.log.error("send failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func startReceiving() {
        let stream = transport.receive()
        receiveTask = Task { [weak self] in
            for await line in stream {
                // An adapter may print a non-JSON line first (a package manager's progress); skip it
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                self?.handle(message)
            }
            self?.failPending(ACPError.exited)
        }
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: error) }
    }

    private func handle(_ message: [String: Any]) {
        let method = message["method"] as? String
        if method == nil, let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: ACPError.agent(error["message"] as? String ?? "The agent returned an error."))
            } else {
                continuation.resume(returning: JSONObject(value: message["result"] as? [String: Any] ?? [:]))
            }
            return
        }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "session/update":
            handleUpdate(params["update"] as? [String: Any] ?? [:])
        case "session/request_permission":
            guard let id = message["id"] else { return }
            Task { await answerPermission(id: id, params: params) }
        default:
            // A request Harbor does not serve (file system, terminal): we told the agent we have neither
            if let id = message["id"] {
                write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Not supported by Harbor"]])
            }
        }
    }

    private func handleUpdate(_ update: [String: Any]) {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if let content = update["content"] as? [String: Any], let text = content["text"] as? String {
                reply += text
                events?.onText(reply)
            }
        case "tool_call":
            let title = update["title"] as? String ?? "tool"
            if let id = update["toolCallId"] as? String { toolTitles[id] = title }
            events?.onTool(title)
        case "config_option_update":
            let updated = ConfigOption.parse(update["configOptions"])
            if !updated.isEmpty {
                options = updated
                events?.onOptions(updated)
            }
        case "tool_call_update":
            if let status = update["status"] as? String, status == "completed" || status == "failed" {
                events?.onTool(nil)
            } else if let title = update["title"] as? String {
                events?.onTool(title)
            }
        default:
            break
        }
    }

    private func answerPermission(id: Any, params: [String: Any]) async {
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let options = params["options"] as? [[String: Any]] ?? []
        let title = toolCall["title"] as? String ?? (toolCall["toolCallId"] as? String).flatMap { toolTitles[$0] } ?? "a browser tool"
        let input = toolCall["rawInput"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any]
        let browserTool = meta?["is_mcp_tool_approval"] as? Bool == true || title.contains("mcp__harbor__") || title.hasPrefix("mcp.harbor.")
        let chosen = await events?.onPermission(title, input, browserTool, options)
        if let chosen {
            respond(to: id, result: ["outcome": ["outcome": "selected", "optionId": chosen]])
        } else {
            respond(to: id, result: ["outcome": ["outcome": "cancelled"]])
        }
    }
}

// MARK: - Launcher

extension ACPClient {
    /// bunx or npx, found on the PATH a login shell sets up. An app started from the Dock gets only
    /// /usr/bin:/bin:/usr/sbin:/sbin, while Bun and Node live wherever the person's shell profile
    /// puts them, so the shell is asked once and the answer kept for the session.
    struct Launcher {
        let command: String
        let args: [String]
        let path: String

        private static var cached: Launcher?
        private static var cachedPath: String?

        static func resolve() async throws -> Launcher {
            if let cached { return cached }
            let path = await loginShellPath()
            let directories = path.split(separator: ":").map(String.init)
            func find(_ name: String) -> String? {
                directories.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
            }
            let launcher: Launcher
            if let bunx = find("bunx") {
                launcher = Launcher(command: bunx, args: [], path: path)
            } else if let npx = find("npx") {
                launcher = Launcher(command: npx, args: ["-y"], path: path)
            } else {
                throw ACPError.launcherMissing
            }
            cached = launcher
            return launcher
        }

        /// The PATH of an interactive login shell, where profiles (`.zprofile`, `.zshrc`) add Bun,
        /// Homebrew and Node. Falls back to the usual install folders if the shell does not answer.
        static func loginShellPath() async -> String {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let fallback = ["\(home)/.bun/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
            if let cachedPath { return cachedPath }
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let path = await Task.detached {
                let process = Process()
                let output = Pipe()
                process.executableURL = URL(fileURLWithPath: shell)
                process.arguments = ["-ilc", "printf '__HARBOR_PATH__%s' \"$PATH\""]
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                guard (try? process.run()) != nil else { return fallback }
                // A profile that waits on something must not hold the chat forever
                DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let text = String(decoding: data, as: UTF8.self)
                guard let range = text.range(of: "__HARBOR_PATH__") else { return fallback }
                let path = String(text[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return path.isEmpty ? fallback : path + ":" + fallback
            }.value
            cachedPath = path
            return path
        }
    }
}
