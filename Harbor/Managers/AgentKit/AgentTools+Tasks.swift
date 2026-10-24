// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Tasks.swift
//  Harbor
//
//  Tasks, handoffs, approvals and the vault's names, for the agent. The person's side of the same
//  actions (take over, hand back, stop, approve) is in the Agent card UI.
//

import Foundation

extension AgentToolbox {
    static let taskTools: [AgentTool] = [
        taskStart, taskList, taskUpdate, taskHandoff, taskWait, taskEnd, taskReplay, approvalWait, secrets
    ]

    private static let taskStart = AgentTool(
        "task_start",
        """
        Start a task: its own Agent space tab, shown to the person as a card with your title and status, which they can watch, take over or stop. \
        Pass task: <id> to every page tool to work in its tab. goal: what the person asked for, in their words; actions that do not fit it ask for approval. \
        allowedOrigins: hosts or origins the tab may open (others are blocked). confirm: sensitive (default: purchases, sends, deletes, sign-ins, scripts) or always.
        """,
        page: .none,
        properties: [
            "title": ["type": "string", "description": "Short, for the card"],
            "goal": ["type": "string"],
            "url": ["type": "string", "description": "Page to open in the task's tab"],
            "allowedOrigins": ["type": "array", "items": ["type": "string"]],
            "confirm": ["type": "string", "enum": ["sensitive", "always"]]
        ],
        required: ["title"]
    ) { call in
        let title = try call.args.required("title")
        let origins = call.args.strings("allowedOrigins") ?? []
        let confirm = try call.args.string("confirm").map { raw -> AgentTask.ConfirmPolicy in
            // Only the person turns approvals off (their own scheduled runs); an agent cannot.
            guard let policy = AgentTask.ConfirmPolicy(rawValue: raw), policy != .never else {
                throw AgentError.invalid("confirm is sensitive or always")
            }
            return policy
        } ?? .sensitive
        var url: URL?
        if let string = call.args.string("url") {
            guard let parsed = AgentURLs.web(string) else { throw AgentError.invalid("\(string) is not an http(s) URL") }
            guard AgentScope.allows(parsed, origins: origins) else { throw AgentError.outOfScope(parsed.host ?? string) }
            url = parsed
        }
        guard let item = call.browser.openAgentTab(url: nil, title: title) else {
            throw AgentError.invalid("No space to borrow logins from")
        }
        let task = AgentTask(id: AgentID.make("t"), title: title, goal: call.args.string("goal"), itemID: item,
                             allowedOrigins: origins, confirm: confirm)
        AgentHub.shared.tasks.add(task)
        if let url {
            let webView = try call.browser.agentWebView(item: item)
            _ = await AgentPageWait.open(webView, url: url, timeout: min(15, call.remaining - 2))
        }
        return .json(task.summary)
    }

    private static let taskList = AgentTool("task_list", "Tasks this session with their status.", page: .none) { _ in
        .json(AgentHub.shared.tasks.all.map(\.summary))
    }

    private static let taskUpdate = AgentTool(
        "task_update", "Tell the person what you are doing now; shown on the task's card.",
        page: .none, properties: ["task": ["type": "string"], "note": ["type": "string"]], required: ["task", "note"]
    ) { call in
        let task = try task(call)
        task.note = String(try call.args.required("note").prefix(300))
        return .json(task.summary)
    }

    private static let taskHandoff = AgentTool(
        "task_handoff",
        "Ask the person to do a step only they can (sign in, enter a code, solve a CAPTCHA, decide). They get a notification; the task's tab waits for them. Then call task_wait until the status is running again.",
        page: .none, properties: ["task": ["type": "string"], "reason": ["type": "string", "description": "What they should do, in a sentence"]],
        required: ["task", "reason"]
    ) { call in
        let task = try task(call)
        guard !task.isFinished else { throw AgentError.invalid("Task \(task.id) has ended") }
        let reason = String(try call.args.required("reason").prefix(200))
        AgentHub.shared.tasks.set(task, .needsYou(reason))
        call.browser.tabs.selectForAgent(task.itemID)
        AgentNotifier.handoff(task, reason: reason)
        return .json(task.summary)
    }

    private static let taskWait = AgentTool(
        "task_wait", "Wait up to timeout seconds (default and most 25) while the person has the task, then return its status. Call again until it is running.",
        page: .none, properties: ["task": ["type": "string"], "timeout": ["type": "number"]], required: ["task"]
    ) { call in
        let task = try task(call)
        let timeout = min(call.args.double("timeout") ?? 25, call.remaining - 1)
        _ = await AgentHub.shared.tasks.changed.wait(until: { !task.isPausedForPerson }, timeout: timeout)
        return .json(task.summary)
    }

    private static let taskEnd = AgentTool(
        "task_end", "Finish a task: outcome done or failed, with a one-line summary for the person. Its tab stays open for them.",
        page: .none,
        properties: ["task": ["type": "string"], "outcome": ["type": "string", "enum": ["done", "failed"]], "summary": ["type": "string"]],
        required: ["task", "outcome"]
    ) { call in
        let task = try task(call)
        let summary = call.args.string("summary").map { String($0.prefix(300)) }
        AgentHub.shared.tasks.set(task, call.args.string("outcome") == "failed" ? .failed(summary) : .done(summary))
        AgentHub.shared.approvals.dropAll(for: task.id)
        return .json(task.summary)
    }

    private static let taskReplay = AgentTool(
        "task_replay", "Every step a task took: tool, detail, result, page and, for steps that changed the page, a picture file. Also saved under the returned dir.",
        page: .none, properties: ["task": ["type": "string"]], required: ["task"]
    ) { call in
        let task = try task(call)
        let steps = AgentHub.shared.replay.steps(for: task).map(\.json)
        return .json(["task": task.id, "dir": AgentReplay.directory(for: task.id).path, "steps": steps])
    }

    private static let approvalWait = AgentTool(
        "approval_wait", "Wait up to timeout seconds (default and most 25) for the person to answer an approval. decision: allowed, denied or pending (call again).",
        page: .none, properties: ["approval": ["type": "string"], "timeout": ["type": "number"]], required: ["approval"]
    ) { call in
        let id = try call.args.required("approval")
        let approvals = AgentHub.shared.approvals
        guard approvals.isKnown(id) else { throw AgentError.invalid("No approval \(id)") }
        let decision = await approvals.wait(id, timeout: min(call.args.double("timeout") ?? 25, call.remaining - 1))
        return .json(["approval": id, "decision": decision?.rawValue ?? "pending"])
    }

    private static let secrets = AgentTool(
        "secrets",
        "Names of the secrets the person stored for you and the sites each may be typed on. Type one with {{secret:name}} in fill or type text; you never see the value.",
        page: .none
    ) { _ in
        .json(AgentHub.shared.vault.entries.map { ["name": $0.name, "domains": $0.domains] })
    }

    private static func task(_ call: AgentCall) throws -> AgentTask {
        let id = try call.args.required("task")
        guard let task = AgentHub.shared.tasks.task(id) else { throw AgentError.unknownTask(id) }
        return task
    }
}
