// Licensed under GPL-3.0. See LICENSE.
//
//  AgentActions.swift
//  Harbor
//
//  Runs Browser Bridge's ActionStep (click, fill, press, waitFor, …) on an agent page. Shared by
//  the `act` tool and the recipe runner. Pointer and key steps use native input by default
//  (AgentInput); typing goes through the page's editor so it arrives as trusted input. Before a
//  step changes anything, the task's policy may ask the person (AgentApprovals).
//

import Foundation
import WebKit

@MainActor
final class AgentActions {
    enum StepError: LocalizedError {
        case needsApproval(id: String, reason: String)
        case covered(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .needsApproval(let id, let reason): "Needs the person's approval (\(reason)). Call approval_wait with approval \(id), then send the remaining steps again."
            case .covered(let what): "Another element covers the target: \(what). Close it first, or pass input: \"dom\"."
            case .invalid(let message): message
            }
        }
    }

    let webView: WKWebView
    let task: AgentTask?
    let deadline: Date
    /// Values bound by `as`, readable in later steps as `${vars.name}`.
    var vars: [String: Any]
    /// Where the pointer was left, so a `human` move starts from there.
    private var lastPointer = CGPoint(x: 40, y: 40)

    /// Pointer steps that default to native input.
    private static let nativeByDefault: Set<String> = ["click", "hover", "mouseMove", "press", "check", "uncheck"]

    init(webView: WKWebView, task: AgentTask?, deadline: Date, vars: [String: Any] = [:]) {
        self.webView = webView
        self.task = task
        self.deadline = deadline
        self.vars = vars
    }

    private var remaining: TimeInterval { max(0, deadline.timeIntervalSinceNow) }

    private func budget(_ step: [String: Any], fallback: TimeInterval) -> TimeInterval {
        let ms = (step["timeout"] as? NSNumber)?.doubleValue
        return min(ms.map { $0 / 1000 } ?? fallback, remaining)
    }

    // MARK: - One step

    /// Runs one step and returns its value (getText, getValue, eval, …) or nil.
    func perform(_ raw: [String: Any]) async throws -> Any? {
        try Task.checkCancellation()
        // Checked before every step: the person may stop or take the task in the middle of a batch.
        if let task {
            if task.isFinished { throw AgentError.invalid("Task \(task.id) has ended") }
            if task.isPausedForPerson { throw AgentError.paused(task.title) }
        }
        let step = AgentTemplate.fill(raw, scopes: ["vars": vars]) as? [String: Any] ?? raw
        guard let action = step["action"] as? String else { throw StepError.invalid("Each step needs an action") }
        let target = step["target"] as? String
        let native = (step["input"] as? String).map { $0 == "native" } ?? Self.nativeByDefault.contains(action)

        // A site the task may not open is refused before anyone is asked to approve it.
        if action == "navigate", let task, let url = (step["url"] as? String).flatMap(AgentURLs.web), !task.allows(url) {
            throw AgentError.outOfScope(url.host ?? url.absoluteString)
        }
        try await checkPolicy(action: action, step: step, target: target)

        switch action {
        case "click":
            let count = (step["clickCount"] as? NSNumber)?.intValue ?? 1
            if native { try await nativeClick(target, step: step, clickCount: count) }
            else { _ = try await runtime("click", ["target": try need(target)]) }
            await settle()
            return nil

        case "fill", "type":
            let text = step["text"] as? String ?? step["value"] as? String ?? ""
            let literal = raw["text"] as? String ?? raw["value"] as? String ?? ""
            var args: [String: Any] = ["target": try need(target), "clear": action == "fill"]
            args.merge(try await secretArgs(text, literal: literal)) { $1 }
            _ = try await runtime("insertText", args)
            return nil

        case "setValue":
            let text = step["value"] as? String ?? step["text"] as? String ?? ""
            let literal = raw["value"] as? String ?? raw["text"] as? String ?? ""
            var args: [String: Any] = ["target": try need(target)]
            args.merge(try await secretArgs(text, literal: literal)) { $1 }
            args["value"] = args.removeValue(forKey: "text")
            _ = try await runtime("setValue", args)
            return nil

        case "select":
            let value = step["value"] ?? step["text"] ?? ""
            let result = try await runtime("select", ["target": try need(target), "value": value]) as? [String: Any]
            return result?["value"]

        case "check", "uncheck":
            let want = action == "check"
            let target = try need(target)
            if native {
                let current = try await runtime("checked", ["target": target]) as? Bool ?? false
                if current != want { try await nativeClick(target, step: step) }
                // The state says whether the press landed, so finishing it in the DOM cannot
                // toggle twice.
                if try await runtime("checked", ["target": target]) as? Bool != want {
                    _ = try await runtime("check", ["target": target, "on": want])
                }
            } else {
                _ = try await runtime("check", ["target": target, "on": want])
            }
            return nil

        case "press":
            guard let key = step["key"] as? String ?? step["text"] as? String else { throw StepError.invalid("press needs a key") }
            if let target { _ = try await runtime("focus", ["target": target]) }
            try AgentInput.press(webView, key)
            await settle()
            return nil

        case "hover", "mouseMove":
            let point = try await runtime("point", pointArgs(target, step)) as? [String: Any] ?? [:]
            let x = (point["x"] as? NSNumber)?.doubleValue ?? 0
            let y = (point["y"] as? NSNumber)?.doubleValue ?? 0
            let viewport = AgentInput.Viewport(point["viewport"])
            if native {
                if step["human"] as? Bool == true {
                    let steps = (step["steps"] as? NSNumber)?.intValue ?? 18
                    try await AgentInput.moveAlong(webView, from: lastPointer, to: CGPoint(x: x, y: y), viewport: viewport, steps: steps)
                } else {
                    try AgentInput.hover(webView, x: x, y: y, viewport: viewport)
                }
                lastPointer = CGPoint(x: x, y: y)
                await AgentInput.afterPendingMouseEvents(webView)
            }
            // WebKit drops pointer moves for a page in the hidden host, so hover menus also get
            // the DOM's pointer events.
            _ = try await runtime("hover", target.map { ["target": $0] } ?? ["x": x, "y": y])
            return nil

        case "focus", "scrollIntoView", "submit":
            _ = try await runtime(action, ["target": try need(target)])
            if action == "submit" { await settle() }
            return nil

        case "scroll":
            return try await scroll(target: target, step: step, native: native)

        case "getText":
            return try await runtime("getText", target.map { ["target": $0] } ?? [:])

        case "getValue":
            return try await runtime("getValue", ["target": try need(target)])

        case "waitFor":
            let timeout = budget(step, fallback: 10)
            let gone = step["state"] as? String == "hidden" || step["gone"] as? Bool == true
            guard try await waitFor(try need(target), timeout: timeout, gone: gone) else {
                throw StepError.invalid("\(target ?? "") did not \(gone ? "go away" : "appear") within \(Int(timeout))s")
            }
            return nil

        case "waitForUrl":
            let pattern = step["url"] as? String ?? target ?? ""
            let timeout = budget(step, fallback: 10)
            guard await AgentPageWait.url(webView, matching: pattern, timeout: timeout) else {
                throw StepError.invalid("URL did not match \(pattern) within \(Int(timeout))s; it is \(webView.url?.absoluteString ?? "")")
            }
            return webView.url?.absoluteString

        case "eval":
            // In a task the person approved scripts already (checkPolicy); elsewhere nobody can.
            if task == nil || task?.confirm == .never, await AgentRuntime.secretTyped(in: webView) {
                throw StepError.invalid(AgentRuntime.secretScriptRefusal)
            }
            let code = step["code"] as? String ?? ""
            let value = try await AgentDeadline.throwing(remaining) { [webView] in
                try await AgentPageWait.evaluate(webView, code: code, arg: step["arg"])
            }
            if let name = step["as"] as? String { vars[name] = value ?? NSNull() }
            return value

        case "navigate":
            guard let string = step["url"] as? String, let url = AgentURLs.web(string) else {
                throw StepError.invalid("navigate needs an http(s) url")
            }
            if let task, !task.allows(url) { throw AgentError.outOfScope(url.host ?? string) }
            _ = await AgentPageWait.open(webView, url: url, timeout: budget(step, fallback: 15))
            return webView.url?.absoluteString

        case "back", "forward", "reload":
            if action == "back" { webView.goBack() } else if action == "forward" { webView.goForward() } else { webView.reload() }
            await settle()
            return webView.url?.absoluteString

        default:
            throw StepError.invalid("Unknown action \(action)")
        }
    }

    // MARK: - Pieces

    private func need(_ target: String?) throws -> String {
        guard let target, !target.isEmpty else { throw StepError.invalid("This step needs a target") }
        return target
    }

    private func runtime(_ op: String, _ args: [String: Any]) async throws -> Any? {
        try await AgentRuntime.call(op, args, in: webView)
    }

    private func pointArgs(_ target: String?, _ step: [String: Any]) -> [String: Any] {
        var args: [String: Any] = [:]
        if let target { args["target"] = target }
        if let x = step["x"] { args["x"] = x }
        if let y = step["y"] { args["y"] = y }
        return args
    }

    private func nativeClick(_ target: String?, step: [String: Any], clickCount: Int = 1) async throws {
        let point = try await runtime("point", pointArgs(target, step)) as? [String: Any] ?? [:]
        let x = (point["x"] as? NSNumber)?.doubleValue ?? 0
        let y = (point["y"] as? NSNumber)?.doubleValue ?? 0
        if point["hit"] as? Bool == false, step["force"] as? Bool != true {
            let covering = point["covering"] as? [String: Any]
            let what = "\(covering?["role"] ?? "element") \"\(covering?["name"] ?? "")\"" + ((covering?["ref"]).map { " (\($0))" } ?? "")
            throw StepError.covered(what)
        }
        let viewport = AgentInput.Viewport(point["viewport"])
        if step["human"] as? Bool == true {
            try await AgentInput.moveAlong(webView, from: lastPointer, to: CGPoint(x: x, y: y), viewport: viewport, steps: 14)
            try await Task.sleep(for: .milliseconds(Int.random(in: 60...160)))
        }
        lastPointer = CGPoint(x: x, y: y)
        // A page just put back into its host learns where it is a moment later and drops a press
        // sent before that; one animation frame in the page comes after it. The press is never
        // repeated: a page may hide it from any check, and pressing twice could buy twice.
        _ = try? await runtime("frame", [:])
        try AgentInput.click(webView, x: x, y: y, viewport: viewport, clickCount: clickCount)
        await AgentInput.afterPendingMouseEvents(webView)
    }

    private func scroll(target: String?, step: [String: Any], native: Bool) async throws -> Any? {
        let deltaY = (step["deltaY"] as? NSNumber)?.doubleValue
        let human = step["human"] as? Bool == true
        // "top"/"bottom" and element scrolling are exact in the DOM; wheel events suit the rest.
        guard native || human, target == nil || target == "top" || target == "bottom" else {
            var args: [String: Any] = [:]
            if let target { args["target"] = target }
            if let deltaY { args["deltaY"] = deltaY }
            return try await runtime("scroll", args)
        }
        if target == "top" || target == "bottom" {
            let state = try await runtime("scroll", ["deltaY": 0]) as? [String: Any] ?? [:]
            let y = (state["scrollY"] as? NSNumber)?.doubleValue ?? 0
            let max = (state["max"] as? NSNumber)?.doubleValue ?? 0
            return try await wheel(total: target == "top" ? -y : max - y, human: human, steps: step["steps"] as? NSNumber)
        }
        return try await wheel(total: deltaY ?? 600, human: human, steps: step["steps"] as? NSNumber)
    }

    /// Wheel events in jittered chunks with short pauses when `human`, else one event.
    private func wheel(total: Double, human: Bool, steps: NSNumber?) async throws -> Any? {
        let viewport = AgentInput.Viewport(try await runtime("point", ["x": 0, "y": 0]).flatMap { ($0 as? [String: Any])?["viewport"] })
        let x = viewport.width / 2, y = viewport.height / 2
        let count = human ? max(1, steps?.intValue ?? Int(min(30, max(4, abs(total) / 120)))) : 1
        var done = 0.0
        for i in 0..<count {
            let share = i == count - 1 ? total - done : (total / Double(count)) * Double.random(in: 0.7...1.3)
            done += share
            try AgentInput.scroll(webView, x: x, y: y, deltaY: share, viewport: viewport)
            if human { try await Task.sleep(for: .milliseconds(Int.random(in: 30...90))) }
        }
        try await Task.sleep(for: .milliseconds(120))
        return try await runtime("scroll", ["deltaY": 0])
    }

    private func waitFor(_ target: String, timeout: TimeInterval, gone: Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let left = deadline.timeIntervalSinceNow
            // The runtime waits on DOM changes itself; a navigation ends its document, so ask again.
            if let ok = try? await runtime("waitFor", ["target": target, "timeout": max(0, left) * 1000, "gone": gone]) as? Bool, ok {
                return true
            }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return false
    }

    /// After a step that may navigate: wait for a load it started, briefly.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(150))
        if webView.isLoading { _ = await AgentPageWait.load(webView, timeout: min(10, remaining)) }
    }

    // MARK: - Secrets and policy

    /// The runtime arguments for typing `text`: the text itself, or with secrets filled in plus the
    /// host they were allowed for, which the runtime checks again at the moment it types (a page
    /// may navigate in between). Only placeholders written in the step itself count: one that came
    /// in through `${vars.x}` (page text an earlier step read) is refused.
    private func secretArgs(_ text: String, literal: String) async throws -> [String: Any] {
        let names = AgentPlaceholders.names(in: text)
        guard !names.isEmpty else { return ["text": text] }
        guard Set(names).isSubset(of: AgentPlaceholders.names(in: literal)) else {
            throw StepError.invalid("A {{secret:…}} placeholder must be written in the step, not come from a variable")
        }
        guard let host = webView.url?.host else { throw StepError.invalid("No site to type a secret into") }
        return ["text": try await AgentHub.shared.vault.fill(text, host: host), "secret": true, "host": host]
    }

    private func checkPolicy(action: String, step: [String: Any], target: String?) async throws {
        guard let task, task.confirm != .never else { return }
        let changes: Set<String> = ["click", "fill", "type", "setValue", "select", "check", "uncheck", "press", "submit", "navigate", "eval"]
        guard changes.contains(action) else { return }
        var facts = AgentActionFacts(action: action)
        facts.host = webView.url?.host ?? ""
        facts.url = webView.url?.absoluteString ?? ""
        facts.key = step["key"] as? String ?? (action == "press" ? step["text"] as? String ?? "" : "")
        facts.text = step["text"] as? String ?? step["value"] as? String ?? (action == "eval" ? step["code"] as? String ?? "" : "")
        facts.typedSecret = !AgentPlaceholders.names(in: facts.text).isEmpty
        var element: [String: Any]?
        if let target {
            element = try? await runtime("describe", ["target": target]) as? [String: Any]
        } else if action == "click", let x = step["x"], let y = step["y"] {
            // A click by position is judged by what is under it, so it cannot go around the rules;
            // when that cannot be found out, it does not happen.
            do {
                element = try await runtime("describeAt", ["x": x, "y": y]) as? [String: Any]
            } catch {
                throw StepError.invalid("Could not tell what is at \(x), \(y): \(error.agentMessage)")
            }
            facts.opaqueTarget = element?["opaque"] as? Bool == true
            facts.text = "\(x),\(y)"
        } else if action == "press" {
            element = try? await runtime("describe", ["target": ":focus"]) as? [String: Any]
        }
        if let element {
            facts.role = element["role"] as? String ?? ""
            facts.name = element["name"] as? String ?? ""
            facts.inputType = element["type"] as? String ?? ""
            facts.element = element["ref"] as? String ?? ""
        }
        if action == "navigate" { facts.host = URL(string: step["url"] as? String ?? "")?.host ?? "" }
        // One approval covers a task's scripts for a while; the person sees the start of this one.
        if action == "eval" { facts.name = String((step["code"] as? String ?? "").prefix(120)) }
        switch await AgentHub.shared.approvals.gate(task: task, facts: facts) {
        case .allowed: return
        case .needsApproval(let request): throw StepError.needsApproval(id: request.id, reason: request.reason)
        case .refused(let why): throw StepError.invalid(why)
        }
    }
}

// MARK: - Waiting on the page

@MainActor
enum AgentPageWait {
    /// Until the page stops loading, or `timeout`. True when it finished.
    static func load(_ webView: WKWebView, timeout: TimeInterval) async -> Bool {
        await until(webView, \.isLoading, timeout: timeout) { !webView.isLoading }
    }

    /// Loads `url` and waits for it. WebKit may start the navigation a moment after `load` (in a
    /// new web process), with `isLoading` still false, and `url` already reads the new address
    /// while the old document shows: waiting on either alone read the previous page. So wait for
    /// the load to start, then to end, then for the page itself to say it is the new document.
    static func open(_ webView: WKWebView, url: URL, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        let previous = webView.url?.absoluteString
        let reloading = previous == url.absoluteString
        webView.load(URLRequest(url: url))
        _ = await until(webView, \.isLoading, timeout: min(3, timeout)) { webView.isLoading }
        guard await load(webView, timeout: max(0, deadline.timeIntervalSinceNow)) else { return false }
        while Date() < deadline {
            let state = try? await webView.callAsyncJavaScript(
                "return [document.readyState, location.href]", contentWorld: AgentRuntime.world) as? [String]
            if let state, state.count == 2, state[0] == "complete", reloading || state[1] != previous {
                return true
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Until the URL contains `pattern`, or matches it when written `/regex/`.
    static func url(_ webView: WKWebView, matching pattern: String, timeout: TimeInterval) async -> Bool {
        let matches: (String) -> Bool
        if pattern.count > 2, pattern.hasPrefix("/"), pattern.hasSuffix("/"),
           let regex = try? NSRegularExpression(pattern: String(pattern.dropFirst().dropLast())) {
            matches = { regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
        } else {
            matches = { $0.contains(pattern) }
        }
        return await until(webView, \.url, timeout: timeout) { matches(webView.url?.absoluteString ?? "") }
    }

    /// Waits for `condition` by observing `keyPath`, never by polling.
    private static func until<Value>(_ webView: WKWebView, _ keyPath: KeyPath<WKWebView, Value>, timeout: TimeInterval,
                                     _ condition: @escaping () -> Bool) async -> Bool {
        if condition() { return true }
        let signal = AgentSignal()
        let observation = webView.observe(keyPath, options: [.new]) { _, _ in
            Task { @MainActor in signal.fire() }
        }
        defer { observation.invalidate() }
        return await signal.wait(until: condition, timeout: timeout)
    }

    /// Runs `code` as an async function body in the page's own world with `arg` bound, and returns
    /// what it returns, JSON-round-tripped so DOM nodes and cycles come back readable.
    static func evaluate(_ webView: WKWebView, code: String, arg: Any?) async throws -> Any? {
        let wrapped = """
        const __v = await (async (arg) => { \(code)
        })(__arg);
        if (__v === undefined) return null;
        try { return JSON.parse(JSON.stringify(__v)); } catch (e) { return String(__v); }
        """
        let result = try await webView.callAsyncJavaScript(wrapped, arguments: ["__arg": arg ?? NSNull()], contentWorld: .page)
        return result is NSNull ? nil : result
    }
}

enum AgentURLs {
    /// Only web pages (and about:blank). A file: URL would load with read access to its folder.
    static func web(_ string: String) -> URL? {
        var string = string.trimmingCharacters(in: .whitespaces)
        if string == "about:blank" { return URL(string: string) }
        if !string.contains("://") { string = "https://" + string }
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }
}
