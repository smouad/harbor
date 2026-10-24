// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Recipes.swift
//  Harbor
//
//  Recording, saving, running and repairing recipes, and running them on a schedule or watching a
//  page for changes.
//

import Foundation
import WebKit

extension AgentToolbox {
    static let recipeTools: [AgentTool] = [
        recordStart, recordStop, recipes, recipeShow, recipeSave, recipeDelete, recipeRun, recipeRepair,
        schedule, schedules, unschedule, watch, watches, watchCheck
    ]

    // MARK: - Recording

    private static let recordStart = AgentTool(
        "record_start",
        "Start recording a recipe from real use: each click, typed field, choice and key in the tab becomes a step. where: person (the tab the person has open; they do the task while you wait) or agent (the task's or Agent space tab, while you drive it). Stop with record_stop.",
        page: .none,
        properties: ["where": ["type": "string", "enum": ["person", "agent"]], "task": ["type": "string"]]
    ) { call in
        let webView: WKWebView
        let subject: String
        if call.args.string("where") == "agent" {
            if let id = call.args.string("task") {
                guard let task = AgentHub.shared.tasks.task(id) else { throw AgentError.unknownTask(id) }
                if task.isFinished { throw AgentError.invalid("Task \(task.id) has ended") }
                if task.isPausedForPerson { throw AgentError.paused(task.title) }
                webView = try call.browser.agentWebView(item: task.itemID)
                subject = task.title
            } else {
                if let refusal = AgentToolbox.taskTabRefusal(call.browser) { throw AgentError.invalid(refusal) }
                guard let view = try call.browser.agentWebView() else { throw AgentError.noPage }
                webView = view
                subject = "Agent"
            }
        } else {
            guard let id = call.window.selectedItemID, let view = call.browser.getWebView(for: id, in: call.window.id)
                    ?? call.browser.tabs.controllableSession(in: call.window)?.webView else {
                throw AgentError.invalid("The person has no tab open")
            }
            webView = view
            subject = view.title ?? "Your tab"
        }
        try await AgentHub.shared.recorder.start(in: webView, subject: subject)
        return .json(["recording": true, "url": webView.url?.absoluteString ?? ""])
    }

    private static let recordStop = AgentTool(
        "record_stop",
        "Stop recording. With name, save it as a recipe (typed text becomes its inputs, with what was typed as defaults); expose: true also makes it a tool, recipe_<name>. Without name, return the steps unsaved.",
        page: .none,
        properties: ["name": ["type": "string"], "description": ["type": "string"], "expose": ["type": "boolean"]]
    ) { call in
        let recorder = AgentHub.shared.recorder
        guard recorder.isRecording else { throw AgentError.invalid("Nothing is being recorded") }
        let steps = recorder.stop()
        guard let name = call.args.string("name") else { return .untrusted(["steps": steps], origin: nil) }
        let recipe = try recorder.recipe(name: name, description: call.args.string("description") ?? "", expose: call.args.bool("expose") ?? false)
        try AgentHub.shared.recipes.save(recipe)
        // Labels and typed text came from the page.
        return .untrusted(recipe.json, origin: recipe.sites.first)
    }

    // MARK: - Recipes

    private static let recipes = AgentTool("recipes", "Saved recipes: name, description, sites, inputs, step count, exposed.", page: .none) { _ in
        .json(AgentHub.shared.recipes.all.map { r -> [String: Any] in
            ["name": r.name, "description": r.description, "sites": r.sites, "vars": r.vars, "steps": r.steps.count, "expose": r.expose]
        })
    }

    private static let recipeShow = AgentTool(
        "recipe_show", "A recipe in full.", page: .none, properties: ["name": ["type": "string"]], required: ["name"]
    ) { call in
        .json(try recipe(call).json)
    }

    private static let recipeSave = AgentTool(
        "recipe_save",
        "Save a recipe (replaces one with the same name): {name, description, sites, vars: {input: default}, expose, steps: [act steps; a step may add targets: [fallback selectors] and label: 'button \"Save\"' for healing]}. Control steps as in Browser Bridge: {foreach: \"${vars.list}\", as: \"item\", steps}, {when: \"vars.n > 2 && item.ok\", steps, else}, set {var, value | expr}, log {message}, goto {target: step id}, snapshot {as}, call {hook, arg, as} running a function from the recipe's hooks (JavaScript source; no page, network or timers). Any step may have id, retry {times, delayMs} and onFail: abort | continue | goto:id; defaults {retry, onFail, timeout} apply to steps without them. ${vars.x} reads inputs and values bound with as, ${input.x} the run's inputs, ${item.x} a foreach item.",
        page: .none,
        properties: ["name": ["type": "string"], "recipe": ["type": "object"]],
        required: ["recipe"]
    ) { call in
        guard let json = call.args.object("recipe") else { throw AgentError.invalid("recipe must be an object") }
        let recipe = try AgentRecipe(json: json, name: call.args.string("name"))
        try AgentHub.shared.recipes.save(recipe)
        return .json(["saved": recipe.name, "steps": recipe.steps.count, "expose": recipe.expose])
    }

    private static let recipeDelete = AgentTool(
        "recipe_delete", "Delete a recipe.", page: .none, properties: ["name": ["type": "string"]], required: ["name"]
    ) { call in
        let recipe = try recipe(call)
        AgentHub.shared.recipes.delete(recipe.name)
        return .json(["deleted": recipe.name])
    }

    private static let recipeRun = AgentTool(
        "recipe_run",
        "Run a recipe as a job, without a model: in the task's tab when task is given (and under its approvals), else in its own tab. A step whose target is gone heals from its fallbacks, its label, then the on-device model; if none works the job waits in needs_repair: look at job_status's repair and answer with recipe_repair. Follow with job_wait.",
        page: .none,
        properties: ["name": ["type": "string"], "vars": ["type": "object"], "task": ["type": "string"]],
        required: ["name"]
    ) { call in
        let task = try call.args.string("task").map { id -> AgentTask in
            guard let task = AgentHub.shared.tasks.task(id) else { throw AgentError.unknownTask(id) }
            return task
        }
        let job = try AgentRecipeRunner.start(name: try call.args.required("name"), vars: call.args.object("vars") ?? [:], task: task)
        return .job(job)
    }

    private static let recipeRepair = AgentTool(
        "recipe_repair",
        "Give a run waiting in needs_repair the target for its broken step (a ref from the repair's elements, or a selector). The run continues and the recipe keeps the new target.",
        page: .none,
        properties: ["job": ["type": "string"], "target": ["type": "string"]],
        required: ["job", "target"]
    ) { call in
        let id = try call.args.required("job")
        guard let job = AgentHub.shared.jobs.job(id), job.state == .needsRepair else {
            throw AgentError.invalid("Job \(id) is not waiting for a repair")
        }
        job.repairTarget = try call.args.required("target")
        job.repaired.fire()
        // Let the run pick the target up before waiting on where it goes next.
        _ = await job.changed.wait(until: { job.state != .needsRepair }, timeout: 3)
        await AgentHub.shared.jobs.wait(job, timeout: min(10, call.remaining - 1))
        return .job(job)
    }

    // MARK: - Schedules and watches

    private static let schedule = AgentTool(
        "schedule",
        "Run a recipe on its own: every N minutes (at least 5) or daily at \"HH:mm\". Runs use the person's logins in their own tab, only while Browser Control is on; a failed run notifies the person.",
        page: .none,
        properties: ["recipe": ["type": "string"], "every": ["type": "integer"], "at": ["type": "string"], "vars": ["type": "object"]],
        required: ["recipe"]
    ) { call in
        let made = try AgentHub.shared.scheduler.addSchedule(
            recipe: try call.args.required("recipe"), everyMinutes: call.args.int("every"), at: call.args.string("at"),
            vars: call.args.object("vars") ?? [:])
        return .json(made.json)
    }

    private static let schedules = AgentTool("schedules", "Scheduled recipes and watched pages.", page: .none) { _ in
        let scheduler = AgentHub.shared.scheduler
        // A watch's sample is page text.
        return .untrusted(["schedules": scheduler.schedules.map(\.json), "watches": scheduler.watches.map(\.json)], origin: nil)
    }

    private static let unschedule = AgentTool(
        "unschedule", "Remove a schedule or a watch by id.", page: .none, properties: ["id": ["type": "string"]], required: ["id"]
    ) { call in
        let id = try call.args.required("id")
        guard AgentHub.shared.scheduler.remove(id) else { throw AgentError.invalid("No schedule or watch \(id)") }
        return .json(["removed": id])
    }

    private static let watch = AgentTool(
        "watch",
        "Watch a page (or the part matching selector) every N minutes (at least 5) and notify the person when its text changes. The first check, right away, records how it looks now.",
        page: .none,
        properties: ["url": ["type": "string"], "selector": ["type": "string"], "every": ["type": "integer"], "name": ["type": "string"]],
        required: ["url", "every"]
    ) { call in
        guard let every = call.args.int("every") else { throw AgentError.invalid("every is a whole number of minutes") }
        let made = try AgentHub.shared.scheduler.addWatch(
            name: call.args.string("name"), url: try call.args.required("url"), selector: call.args.string("selector"), everyMinutes: every)
        return .json(made.json)
    }

    private static let watches = AgentTool("watches", "Watched pages with their last check and how many changes were seen.", page: .none) { _ in
        .untrusted(AgentHub.shared.scheduler.watches.map(\.json), origin: nil)
    }

    private static let watchCheck = AgentTool(
        "watch_check", "Check a watched page now, as a job.", page: .none, properties: ["id": ["type": "string"]], required: ["id"]
    ) { call in
        let id = try call.args.required("id")
        guard let job = AgentHub.shared.scheduler.check(id) else { throw AgentError.invalid("No watch \(id)") }
        return .job(job)
    }

    private static func recipe(_ call: AgentCall) throws -> AgentRecipe {
        let name = try call.args.required("name")
        guard let recipe = AgentHub.shared.recipes.recipe(name) else { throw AgentError.invalid("No recipe named \(name)") }
        return recipe
    }
}
