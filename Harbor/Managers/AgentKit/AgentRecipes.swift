// Licensed under GPL-3.0. See LICENSE.
//
//  AgentRecipes.swift
//  Harbor
//
//  A recipe is a saved browser task: Browser Bridge's step format (navigate, click, fill, …) with
//  `${vars.x}` inputs, recorded from the person's own clicks (AgentRecorder) or written by an
//  agent. Harbor runs it without a model. A step whose target no longer exists heals itself: first
//  from the step's other recorded selectors, then by name, then by asking the on-device model to
//  pick the control from the page's list, and last by pausing the run (needs_repair) until an agent
//  supplies a target. Whatever worked is saved back into the recipe, so the next run is direct.
//  A recipe marked `expose` becomes its own tool, `recipe_<name>`.
//

import Foundation
import Observation
import WebKit
import HarborWeb

struct AgentRecipe {
    var name: String
    var description: String
    var sites: [String]
    /// Inputs with their defaults.
    var vars: [String: Any]
    var expose: Bool
    var steps: [[String: Any]]
    var updated: Date

    /// Step actions Harbor runs. Browser Bridge's control steps (foreach, when, call, goto,
    /// snapshot) need its CLI runner.
    static let actions: Set<String> = [
        "click", "fill", "type", "setValue", "select", "check", "uncheck", "press", "hover", "focus", "scrollIntoView",
        "scroll", "mouseMove", "waitFor", "waitForUrl", "submit", "getText", "getValue", "eval", "navigate", "back",
        "forward", "reload", "log", "set"
    ]

    init(name: String, description: String = "", sites: [String] = [], vars: [String: Any] = [:],
         expose: Bool = false, steps: [[String: Any]], updated: Date = Date()) {
        self.name = name
        self.description = description
        self.sites = sites
        self.vars = vars
        self.expose = expose
        self.steps = steps
        self.updated = updated
    }

    /// Reads and checks a recipe, with every problem in one message.
    init(json: [String: Any], name fallbackName: String? = nil) throws {
        guard let name = (json["name"] as? String) ?? fallbackName, Self.isValidName(name) else {
            throw AgentError.invalid("A recipe needs a name of letters, digits, dash or underscore, other than \(Self.reservedNames.sorted().joined(separator: ", "))")
        }
        guard let steps = json["steps"] as? [[String: Any]], !steps.isEmpty else {
            throw AgentError.invalid("Recipe \(name) has no steps")
        }
        var problems: [String] = []
        for (i, step) in steps.enumerated() {
            let action = step["action"] as? String ?? ""
            if !Self.actions.contains(action) {
                problems.append("step \(i + 1): \(action.isEmpty ? "no action" : "\(action) is not supported here")")
            }
        }
        guard problems.isEmpty else { throw AgentError.invalid("Recipe \(name): " + problems.joined(separator: "; ")) }
        self.init(name: name, description: json["description"] as? String ?? "", sites: json["sites"] as? [String] ?? [],
                  vars: json["vars"] as? [String: Any] ?? [:], expose: json["expose"] as? Bool ?? false, steps: steps,
                  updated: (json["updated"] as? String).flatMap(ISO8601DateFormatter().date(from:)) ?? Date())
    }

    var json: [String: Any] {
        ["name": name, "description": description, "sites": sites, "vars": vars, "expose": expose, "steps": steps,
         "updated": ISO8601DateFormatter().string(from: updated)]
    }

    /// Names whose `recipe_<name>` tool would be shadowed by a built-in one.
    static let reservedNames: Set<String> = ["show", "save", "delete", "run", "repair"]

    static func isValidName(_ name: String) -> Bool {
        name.range(of: #"^[A-Za-z0-9_-]{1,60}$"#, options: .regularExpression) != nil && !reservedNames.contains(name.lowercased())
    }
}

// MARK: - Store

@MainActor
@Observable
final class AgentRecipeStore {
    private(set) var all: [AgentRecipe] = []

    static var directory: URL { AgentHub.directory.appendingPathComponent("recipes", isDirectory: true) }

    func load() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.directory, includingPropertiesForKeys: nil)) ?? []
        all = files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            do {
                return try AgentRecipe(json: json, name: file.deletingPathExtension().lastPathComponent)
            } catch {
                AgentHub.log.error("Skipped recipe \(file.lastPathComponent, privacy: .public): \(error.agentMessage, privacy: .public)")
                return nil
            }
        }.sorted { $0.name < $1.name }
    }

    func recipe(_ name: String) -> AgentRecipe? { all.first { $0.name == name } }

    func save(_ recipe: AgentRecipe) throws {
        var recipe = recipe
        recipe.updated = Date()
        let data = try JSONSerialization.data(withJSONObject: recipe.json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try data.write(to: Self.directory.appendingPathComponent("\(recipe.name).json"), options: .atomic)
        all.removeAll { $0.name == recipe.name }
        all.append(recipe)
        all.sort { $0.name < $1.name }
    }

    func delete(_ name: String) {
        try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent("\(name).json"))
        all.removeAll { $0.name == name }
    }

    /// Exposed recipes as tools. The run waits up to 20 s for the result, then hands back the job.
    var exposedTools: [AgentTool] {
        all.filter(\.expose).map { recipe in
            var properties: [String: Any] = [:]
            for (key, value) in recipe.vars {
                let type = value is NSNumber ? (CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() ? "boolean" : "number") : "string"
                properties[key] = ["type": type, "description": "Default: \(value)"]
            }
            let about = recipe.description.isEmpty ? "Runs the saved recipe \(recipe.name)" : recipe.description
            let sites = recipe.sites.isEmpty ? "" : " (\(recipe.sites.joined(separator: ", ")))"
            return AgentTool("recipe_\(recipe.name)", about + sites + ". Answers with the run's result, or a job id when it takes longer than 20 s.",
                             page: .none, properties: properties) { call in
                let job = try AgentRecipeRunner.start(name: recipe.name, vars: call.args.raw, task: nil)
                await AgentHub.shared.jobs.wait(job, timeout: min(20, call.remaining - 2))
                return .job(job)
            }
        }
    }
}

// MARK: - Runner

@MainActor
enum AgentRecipeRunner {
    /// Starts a run as a job: in the task's tab when given, else in a new Agent space tab that
    /// closes when the run ends.
    static func start(name: String, vars: [String: Any], task: AgentTask?) throws -> AgentJob {
        guard let recipe = AgentHub.shared.recipes.recipe(name) else { throw AgentError.invalid("No recipe named \(name)") }
        guard let browser = AgentHub.shared.browser else { throw AgentError.noPage }
        var inputs = recipe.vars
        for (key, value) in vars where key != "task" { inputs[key] = value }
        return AgentHub.shared.jobs.start(kind: "recipe", title: recipe.name, taskID: task?.id) { job in
            job.total = recipe.steps.count
            let item: UUID
            var ownTab = false
            if let task {
                item = task.itemID
            } else {
                // A run without a task stays on the recipe's sites.
                guard let opened = browser.openAgentTab(url: nil, title: "Recipe: \(recipe.name)", scope: recipe.sites) else { throw AgentError.noPage }
                item = opened
                ownTab = true
            }
            defer { if ownTab { browser.closeAgentTab(item) } }
            return try await run(recipe, inputs: inputs, job: job, task: task, item: item)
        }
    }

    private static func run(_ original: AgentRecipe, inputs: [String: Any], job: AgentJob, task: AgentTask?, item: UUID) async throws -> [String: Any] {
        guard let browser = AgentHub.shared.browser else { throw AgentError.noPage }
        var recipe = original
        var healed = false
        var log: [String] = []
        // One long deadline: a run is a job, not a tool call.
        let actions = AgentActions(webView: try browser.agentWebView(item: item), task: task,
                                   deadline: Date().addingTimeInterval(3600), vars: inputs)
        for index in recipe.steps.indices {
            try Task.checkCancellation()
            if let task, task.isPausedForPerson || task.isFinished {
                throw AgentError.paused(task.title)
            }
            let step = recipe.steps[index]
            let action = step["action"] as? String ?? ""
            job.progress(index, of: recipe.steps.count, "\(index + 1). \(step["label"] as? String ?? action)")
            switch action {
            case "log":
                log.append(AgentTemplate.fill(step["text"] as? String ?? "", scopes: ["vars": actions.vars]) as? String ?? "")
                continue
            case "set":
                if let name = step["name"] as? String ?? step["as"] as? String {
                    actions.vars[name] = AgentTemplate.fill(step["value"] ?? NSNull(), scopes: ["vars": actions.vars])
                }
                continue
            default: break
            }
            // The inputs go in before looking for a target: `text=${vars.item}` names an element only
            // once filled. Steps whose target is not an element are run as written.
            var runnable = step
            let filled = AgentTemplate.fill(step, scopes: ["vars": actions.vars]) as? [String: Any] ?? step
            if Self.targetsElement(filled), let wanted = filled["target"] as? String {
                _ = try browser.agentWebView(item: item)
                let target = try await findTarget(filled, index: index, job: job, webView: actions.webView)
                if target != wanted {
                    runnable["target"] = target
                    // A templated target stays templated; a healed one is saved for next time.
                    if (step["target"] as? String)?.contains("${") != true {
                        recipe.steps[index] = learned(step, target: target)
                        healed = true
                    }
                }
            }
            let value = try await perform(runnable, actions: actions, index: index, job: job, item: item)
            if let name = step["as"] as? String { actions.vars[name] = value ?? NSNull() }
        }
        job.progress(recipe.steps.count, of: recipe.steps.count, "Done")
        if healed {
            try? AgentHub.shared.recipes.save(recipe)
            log.append("Updated the recipe with the targets that worked")
        }
        var outputs: [String: Any] = ["vars": actions.vars.filter { original.vars[$0.key] == nil }]
        if !log.isEmpty { outputs["log"] = log }
        if healed { outputs["healed"] = true }
        return outputs
    }

    /// Steps whose `target` is an element on the page, so a missing one can heal.
    private static func targetsElement(_ step: [String: Any]) -> Bool {
        guard let action = step["action"] as? String, let target = step["target"] as? String, !target.isEmpty else { return false }
        switch action {
        case "scroll": return target != "top" && target != "bottom"
        case "waitFor", "waitForUrl", "navigate", "eval", "back", "forward", "reload", "mouseMove": return false
        default: return true
        }
    }

    /// Runs a step; one that needs the person's approval waits for it (a run is a job, so it can).
    /// The page is hosted again right before each try: a long wait lets the idle timer park it.
    private static func perform(_ step: [String: Any], actions: AgentActions, index: Int, job: AgentJob, item: UUID) async throws -> Any? {
        while true {
            _ = try AgentHub.shared.browser?.agentWebView(item: item)
            do {
                return try await actions.perform(step)
            } catch AgentActions.StepError.needsApproval(let id, let reason) {
                job.progress(index, of: nil, "Step \(index + 1) waits for your approval: \(reason)")
                job.pendingApproval = id
                let decision = await AgentHub.shared.approvals.wait(id, timeout: 3600)
                job.pendingApproval = nil
                try Task.checkCancellation()
                guard decision == .allowed else {
                    throw AgentError.invalid("Step \(index + 1) was not approved")
                }
            } catch let error as AgentActions.StepError {
                throw AgentError.invalid("Step \(index + 1) (\(step["action"] as? String ?? "")): \(error.agentMessage)")
            }
        }
    }

    /// The step's target if it is on the page, else one that heals it, else waits for a repair.
    private static func findTarget(_ step: [String: Any], index: Int, job: AgentJob, webView: WKWebView) async throws -> String {
        let primary = step["target"] as? String ?? ""
        let candidates = [primary] + ((step["targets"] as? [String]) ?? []).filter { $0 != primary }
        // Give a page that is still building its UI a moment on the main target before healing.
        if await exists(primary, in: webView, timeout: 3) { return primary }
        for candidate in candidates.dropFirst() {
            if await exists(candidate, in: webView, timeout: 0) { return candidate }
        }
        let label = step["label"] as? String ?? ""
        if let byName = await healByName(label, in: webView) { return byName }
        if let picked = try await healOnDevice(step: step, label: label, in: webView) { return await durable(picked, in: webView) }
        let repaired = try await waitForRepair(step: step, index: index, tried: candidates, job: job, webView: webView)
        return await durable(repaired, in: webView)
    }

    /// A ref (e17) only lasts for this page, so a recipe keeps the element's best selector instead.
    private static func durable(_ target: String, in webView: WKWebView) async -> String {
        guard target.range(of: #"^e\d+$"#, options: .regularExpression) != nil,
              let found = try? await AgentRuntime.object("selectors", ["target": target], in: webView),
              let best = (found["candidates"] as? [String])?.first else { return target }
        return best
    }

    private static func exists(_ target: String, in webView: WKWebView, timeout: Double) async -> Bool {
        if timeout > 0 {
            return (try? await AgentRuntime.call("waitFor", ["target": target, "timeout": timeout * 1000], in: webView)) as? Bool ?? false
        }
        return (try? await AgentRuntime.call("exists", ["target": target], in: webView)) as? Bool ?? false
    }

    /// A label such as `button "Save"` gives `role=button[name="Save"]`, then `text=Save`.
    private static func healByName(_ label: String, in webView: WKWebView) async -> String? {
        guard let match = label.firstMatch(of: #/^([\w-]+) "(.+)"$/#) else { return nil }
        let (role, name) = (String(match.1), String(match.2))
        guard !name.contains("\"") else { return nil }
        for candidate in ["role=\(role)[name=\"\(name)\"]", "text=\(name)"] {
            if await exists(candidate, in: webView, timeout: 0) { return candidate }
        }
        return nil
    }

    private static func healOnDevice(step: [String: Any], label: String, in webView: WKWebView) async throws -> String? {
        guard AgentOnDevice.isAvailable, !label.isEmpty else { return nil }
        let observed = try await AgentRuntime.object("observe", ["limit": 120], in: webView)
        let elements = observed["elements"] as? [[String: Any]] ?? []
        guard !elements.isEmpty else { return nil }
        return await AgentOnDevice.pickElement(described: label, action: step["action"] as? String ?? "click", among: elements)
    }

    /// Pauses the run until an agent calls recipe_repair with a target, or the job is cancelled.
    private static func waitForRepair(step: [String: Any], index: Int, tried: [String], job: AgentJob, webView: WKWebView) async throws -> String {
        let observed = try? await AgentRuntime.object("observe", ["limit": 80], in: webView)
        job.repair = [
            "step": index + 1, "action": step["action"] as? String ?? "", "label": step["label"] as? String ?? "",
            "tried": tried, "url": webView.url?.absoluteString ?? "",
            "elements": AgentUntrusted.wrap(AgentJSON.compact(observed?["elements"] ?? []), origin: webView.url?.host)
        ]
        job.state = .needsRepair
        job.repairTarget = nil
        job.changed.fire()
        AgentNotifier.runFinished(title: job.title, ok: false, detail: "Step \(index + 1) needs a new target")
        while job.repairTarget == nil {
            try Task.checkCancellation()
            guard job.state == .needsRepair else { throw CancellationError() }
            _ = await job.repaired.wait(timeout: 3600)
        }
        let target = job.repairTarget!
        job.repair = nil
        job.state = .running
        job.changed.fire()
        return target
    }

    /// The step with `target` first and the old targets kept as fallbacks.
    private static func learned(_ step: [String: Any], target: String) -> [String: Any] {
        var step = step
        let previous = [step["target"] as? String].compactMap { $0 } + ((step["targets"] as? [String]) ?? [])
        step["target"] = target
        step["targets"] = Array(([target] + previous).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(6))
        return step
    }
}
