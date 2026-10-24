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
//  Control steps are Browser Bridge's: `foreach` over a list with `as`, `when` with `else`, `set`
//  (a `value` or an `expr`), `goto` a step `id` in the same block, `snapshot as`, `call` a hook
//  (AgentHooks), and per step `retry: {times, delayMs}` and `onFail: abort | continue | goto:id`,
//  defaulting to the recipe's `defaults`. Expressions are AgentExpression.
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
    /// JavaScript for `call` steps (AgentHooks).
    var hooks: String?
    /// `retry`, `onFail` and `timeout` for steps that set none.
    var defaults: [String: Any]
    var updated: Date

    /// Step actions Harbor runs; `foreach` and `when` steps have no action.
    static let actions: Set<String> = [
        "click", "fill", "type", "setValue", "select", "check", "uncheck", "press", "hover", "focus", "scrollIntoView",
        "scroll", "mouseMove", "waitFor", "waitForUrl", "submit", "getText", "getValue", "eval", "navigate", "back",
        "forward", "reload", "log", "set", "snapshot", "call", "goto"
    ]

    init(name: String, description: String = "", sites: [String] = [], vars: [String: Any] = [:],
         expose: Bool = false, steps: [[String: Any]], hooks: String? = nil, defaults: [String: Any] = [:],
         updated: Date = Date()) {
        self.name = name
        self.description = description
        self.sites = sites
        self.vars = vars
        self.expose = expose
        self.steps = steps
        self.hooks = hooks
        self.defaults = defaults
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
        let hooks = json["hooks"] as? String
        var problems = Self.problems(in: steps, at: "step ", hasHooks: hooks != nil)
        if let onFail = (json["defaults"] as? [String: Any])?["onFail"] as? String, onFail.hasPrefix("goto:") {
            problems.append("defaults: onFail goto would jump in every block; set it on the step")
        }
        if let hooks {
            do { try AgentHooks.check(hooks) } catch { problems.append(error.agentMessage) }
        }
        guard problems.isEmpty else { throw AgentError.invalid("Recipe \(name): " + problems.joined(separator: "; ")) }
        self.init(name: name, description: json["description"] as? String ?? "", sites: json["sites"] as? [String] ?? [],
                  vars: json["vars"] as? [String: Any] ?? [:], expose: json["expose"] as? Bool ?? false, steps: steps,
                  hooks: hooks, defaults: json["defaults"] as? [String: Any] ?? [:],
                  updated: (json["updated"] as? String).flatMap(ISO8601DateFormatter().date(from:)) ?? Date())
    }

    /// What is wrong with a block of steps and the blocks inside it, as "step 2.1: …". A goto may
    /// name a step in its own block or any block around it (`outer`).
    private static func problems(in steps: [[String: Any]], at prefix: String, hasHooks: Bool, outer: Set<String> = []) -> [String] {
        let ids = outer.union(steps.compactMap { $0["id"] as? String })
        var problems: [String] = []
        for (i, step) in steps.enumerated() {
            let at = "\(prefix)\(i + 1)"
            if let onFail = step["onFail"] as? String, onFail.hasPrefix("goto:"), !ids.contains(String(onFail.dropFirst(5))) {
                problems.append("\(at): onFail \(onFail) names no step id in its block or around it")
            }
            if step["foreach"] != nil {
                guard step["foreach"] is String, step["as"] is String, let inner = step["steps"] as? [[String: Any]] else {
                    problems.append("\(at): foreach needs a list (\"${vars.items}\"), as and steps"); continue
                }
                problems += Self.problems(in: inner, at: at + ".", hasHooks: hasHooks, outer: ids)
            } else if step["when"] != nil {
                guard step["when"] is String, let inner = step["steps"] as? [[String: Any]] else {
                    problems.append("\(at): when needs an expression and steps"); continue
                }
                problems += Self.problems(in: inner, at: at + ".", hasHooks: hasHooks, outer: ids)
                if let other = step["else"] {
                    guard let otherSteps = other as? [[String: Any]] else { problems.append("\(at): else is a list of steps"); continue }
                    problems += Self.problems(in: otherSteps, at: at + " else ", hasHooks: hasHooks, outer: ids)
                }
            } else {
                let action = step["action"] as? String ?? ""
                if !Self.actions.contains(action) {
                    problems.append("\(at): \(action.isEmpty ? "no action" : "\(action) is not supported here")")
                } else if action == "goto", let target = step["target"] as? String, !target.contains("${"), !ids.contains(target) {
                    problems.append("\(at): goto \(target) names no step id in its block or around it")
                } else if action == "call", step["hook"] as? String == nil || !hasHooks {
                    problems.append("\(at): call needs a hook and the recipe's hooks")
                } else if action == "set", (step["var"] ?? step["name"] ?? step["as"]) as? String == nil {
                    problems.append("\(at): set needs var")
                }
            }
        }
        return problems
    }

    var json: [String: Any] {
        var json: [String: Any] = ["name": name, "description": description, "sites": sites, "vars": vars, "expose": expose,
                                   "steps": steps, "updated": ISO8601DateFormatter().string(from: updated)]
        if let hooks { json["hooks"] = hooks }
        if !defaults.isEmpty { json["defaults"] = defaults }
        return json
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

    /// One run's state, shared by the nested blocks of steps.
    @MainActor
    private final class Run {
        var recipe: AgentRecipe
        let original: AgentRecipe
        let inputs: [String: Any]
        let actions: AgentActions
        let job: AgentJob
        let task: AgentTask?
        let item: UUID
        var healed = false
        var log: [String] = []
        var executed = 0
        /// `foreach` items by their `as` name, readable as `${item.x}`.
        var aliases: [String: Any] = [:]
        var failed: [[String: Any]] = []

        init(recipe: AgentRecipe, inputs: [String: Any], actions: AgentActions, job: AgentJob, task: AgentTask?, item: UUID) {
            self.recipe = recipe
            self.original = recipe
            self.inputs = inputs
            self.actions = actions
            self.job = job
            self.task = task
            self.item = item
        }

        var scopes: [String: Any] {
            aliases.merging(["vars": actions.vars, "input": inputs]) { _, own in own }
        }
    }

    /// Where a step sits: its index in each block from the top, each with the branch of that step
    /// (`steps` or `else`) the next index is in.
    private typealias StepPath = [(index: Int, branch: String)]

    /// A run stops after this many steps, so a `goto` loop cannot run forever.
    private static let maxSteps = 5000

    private struct Jump: Error { let id: String }

    private static func run(_ original: AgentRecipe, inputs: [String: Any], job: AgentJob, task: AgentTask?, item: UUID) async throws -> [String: Any] {
        guard let browser = AgentHub.shared.browser else { throw AgentError.noPage }
        // One long deadline: a run is a job, not a tool call.
        let actions = AgentActions(webView: try browser.agentWebView(item: item), task: task,
                                   deadline: Date().addingTimeInterval(3600), vars: inputs)
        let run = Run(recipe: original, inputs: inputs, actions: actions, job: job, task: task, item: item)
        do {
            try await runBlock(original.steps, path: [], run: run)
        } catch let jump as Jump {
            throw AgentError.invalid("goto \(jump.id): no step has that id in its block")
        }
        job.progress(original.steps.count, of: original.steps.count, "Done")
        if run.healed {
            try? AgentHub.shared.recipes.save(run.recipe)
            run.log.append("Updated the recipe with the targets that worked")
        }
        var outputs: [String: Any] = ["vars": actions.vars.filter { original.vars[$0.key] == nil }]
        if !run.log.isEmpty { outputs["log"] = run.log }
        if !run.failed.isEmpty { outputs["failed"] = run.failed }
        if run.healed { outputs["healed"] = true }
        return outputs
    }

    /// Runs a block of steps in order; a `goto` to an id in this block moves there, one to an id
    /// elsewhere goes up to the block that has it.
    private static func runBlock(_ steps: [[String: Any]], path: StepPath, run: Run) async throws {
        var index = 0
        while index < steps.count {
            let step = steps[index]
            let here = path + [(index, "steps")]
            do {
                try await runStep(step, path: here, run: run)
                index += 1
            } catch let jump as Jump {
                guard let target = steps.firstIndex(where: { $0["id"] as? String == jump.id }) else { throw jump }
                index = target
            }
        }
    }

    private static func runStep(_ step: [String: Any], path: StepPath, run: Run) async throws {
        try Task.checkCancellation()
        if let task = run.task, task.isPausedForPerson || task.isFinished { throw AgentError.paused(task.title) }
        run.executed += 1
        guard run.executed <= maxSteps else { throw AgentError.invalid("Stopped after \(maxSteps) steps; a goto may loop") }
        let label = Self.label(step, path: path)
        run.job.progress(path[0].index, of: run.recipe.steps.count, label)

        if let source = step["foreach"] as? String, let name = step["as"] as? String, let inner = step["steps"] as? [[String: Any]] {
            let list = try value(of: source, run: run)
            guard let items = list as? [Any] else { throw AgentError.invalid("\(label): foreach needs a list, got \(AgentExpression.text(list))") }
            // Also when a goto leaves the loop.
            defer {
                run.aliases.removeValue(forKey: name)
                run.actions.vars.removeValue(forKey: name)
                run.actions.scopes = run.scopes
            }
            for (i, item) in items.enumerated() {
                run.aliases[name] = item
                run.actions.vars[name] = item
                run.actions.scopes = run.scopes
                run.job.progress(path[0].index, of: run.recipe.steps.count, "\(label) \(i + 1)/\(items.count)")
                try await runBlock(inner, path: path, run: run)
            }
            return
        }
        if let condition = step["when"] as? String {
            let holds = AgentExpression.truthy(try value(of: condition, run: run))
            if holds, let inner = step["steps"] as? [[String: Any]] {
                try await runBlock(inner, path: path, run: run)
            } else if !holds, let other = step["else"] as? [[String: Any]] {
                var elsePath = path
                elsePath[elsePath.count - 1].branch = "else"
                try await runBlock(other, path: elsePath, run: run)
            }
            return
        }

        let action = step["action"] as? String ?? ""
        let filledStep = { AgentTemplate.fill(step, scopes: run.scopes) as? [String: Any] ?? step }
        switch action {
        case "log":
            let text = filledStep()["message"] ?? filledStep()["text"] ?? ""
            run.log.append(text as? String ?? AgentExpression.text(text))
            return
        case "set":
            guard let name = (step["var"] ?? step["name"] ?? step["as"]) as? String else { return }
            if let expression = step["expr"] as? String {
                run.actions.vars[name] = try value(of: expression, run: run)
            } else {
                run.actions.vars[name] = AgentTemplate.fill(step["value"] ?? NSNull(), scopes: run.scopes)
            }
            run.actions.scopes = run.scopes
            return
        case "goto":
            throw Jump(id: filledStep()["target"] as? String ?? "")
        default:
            break
        }

        let retry = (step["retry"] ?? run.recipe.defaults["retry"]) as? [String: Any]
        let attempts = max(0, (retry?["times"] as? NSNumber)?.intValue ?? 0) + 1
        let delay = ((retry?["delayMs"] as? NSNumber)?.doubleValue ?? 500) / 1000
        var lastError: Error?
        for attempt in 1...attempts {
            do {
                let value = try await perform(step, label: label, path: path, run: run)
                if let name = step["as"] as? String {
                    run.actions.vars[name] = value ?? NSNull()
                    run.actions.scopes = run.scopes
                }
                return
            } catch let error where !(error is CancellationError) && !Self.isPause(error) {
                lastError = error
                if attempt < attempts { try await Task.sleep(for: .seconds(delay)) }
            }
        }
        let message = lastError?.agentMessage ?? "failed"
        let onFail = (step["onFail"] ?? run.recipe.defaults["onFail"]) as? String ?? "abort"
        if onFail == "continue" {
            run.failed.append(["step": label, "error": message])
            run.log.append("\(label) failed: \(message)")
            return
        }
        if onFail.hasPrefix("goto:") {
            run.log.append("\(label) failed: \(message)")
            throw Jump(id: String(onFail.dropFirst(5)))
        }
        throw lastError ?? AgentError.invalid("\(label) failed")
    }

    /// One step that acts on the page, a snapshot or a hook call.
    private static func perform(_ step: [String: Any], label: String, path: StepPath, run: Run) async throws -> Any? {
        switch step["action"] as? String {
        case "snapshot":
            _ = try AgentHub.shared.browser?.agentWebView(item: run.item)
            let observed = try await AgentRuntime.object("observe", ["limit": (step["limit"] as? NSNumber)?.intValue ?? 200], in: run.actions.webView)
            return observed["elements"] ?? []
        case "call":
            let filled = AgentTemplate.fill(step, scopes: run.scopes) as? [String: Any] ?? step
            return try await AgentHooks.call(filled["hook"] as? String ?? "", source: run.recipe.hooks ?? "",
                                             arg: filled["arg"], vars: run.actions.vars, input: run.inputs)
        default:
            break
        }
        // The inputs go in before looking for a target: `text=${vars.item}` names an element only
        // once filled. Steps whose target is not an element are run as written.
        var runnable = step
        if runnable["timeout"] == nil, let timeout = run.recipe.defaults["timeout"] { runnable["timeout"] = timeout }
        let filled = AgentTemplate.fill(step, scopes: run.scopes) as? [String: Any] ?? step
        if Self.targetsElement(filled), let wanted = filled["target"] as? String {
            _ = try AgentHub.shared.browser?.agentWebView(item: run.item)
            // A step that says what to do when it fails does that instead of waiting for a repair.
            let failsOver = ((step["onFail"] ?? run.recipe.defaults["onFail"]) as? String ?? "abort") != "abort"
            let target = try await findTarget(filled, index: path[0].index, job: run.job, webView: run.actions.webView,
                                              mayPause: !failsOver)
            if target != wanted {
                runnable["target"] = target
                // A templated target stays templated; a healed one is saved for next time.
                if (step["target"] as? String)?.contains("${") != true {
                    Self.update(&run.recipe.steps, at: path, to: learned(step, target: target))
                    run.healed = true
                }
            }
        }
        return try await perform(runnable, actions: run.actions, index: path[0].index, job: run.job, item: run.item)
    }

    /// A paused or ended task stops the run; retries and onFail do not apply.
    private static func isPause(_ error: Error) -> Bool {
        if case AgentError.paused = error { return true }
        return false
    }

    private static func value(of expression: String, run: Run) throws -> Any {
        // `${vars.items}` and `vars.items` mean the same.
        var text = expression.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("${"), text.hasSuffix("}"), text.dropFirst(2).firstIndex(of: "}") == text.index(before: text.endIndex) {
            text = String(text.dropFirst(2).dropLast())
        }
        do {
            return try AgentExpression.evaluate(text, scopes: run.scopes)
        } catch {
            throw AgentError.invalid(error.agentMessage)
        }
    }

    private static func label(_ step: [String: Any], path: StepPath) -> String {
        let number = path.map { String($0.index + 1) + ($0.branch == "else" ? " else" : "") }.joined(separator: ".")
        let what = step["id"] as? String ?? step["label"] as? String ?? (step["foreach"] != nil ? "foreach" : nil)
            ?? (step["when"] != nil ? "when" : nil) ?? step["action"] as? String ?? "step"
        return "\(number). \(what)"
    }

    /// Replaces the step at `path` inside nested blocks.
    private static func update(_ steps: inout [[String: Any]], at path: StepPath, to new: [String: Any]) {
        guard let first = path.first, steps.indices.contains(first.index) else { return }
        if path.count == 1 { steps[first.index] = new; return }
        var container = steps[first.index]
        var block = container[first.branch] as? [[String: Any]] ?? []
        update(&block, at: Array(path.dropFirst()), to: new)
        container[first.branch] = block
        steps[first.index] = container
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
    private static func findTarget(_ step: [String: Any], index: Int, job: AgentJob, webView: WKWebView,
                                   mayPause: Bool = true) async throws -> String {
        let primary = step["target"] as? String ?? ""
        let candidates = [primary] + ((step["targets"] as? [String]) ?? []).filter { $0 != primary }
        // Give a page that is still building its UI a moment on the main target before healing.
        let wait = min(3, ((step["timeout"] as? NSNumber)?.doubleValue).map { $0 / 1000 } ?? 3)
        if await exists(primary, in: webView, timeout: wait) { return primary }
        for candidate in candidates.dropFirst() {
            if await exists(candidate, in: webView, timeout: 0) { return candidate }
        }
        let label = step["label"] as? String ?? ""
        if let byName = await healByName(label, in: webView) { return byName }
        if let picked = try await healOnDevice(step: step, label: label, in: webView) { return await durable(picked, in: webView) }
        guard mayPause else { throw AgentError.invalid("\(primary) is not on the page") }
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
