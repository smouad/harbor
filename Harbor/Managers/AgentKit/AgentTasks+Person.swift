// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTasks+Person.swift
//  Harbor
//
//  What the person does to a task from the Agent card: watch it, take the controls and give them
//  back, finish a step they were handed, or stop it. The agent learns of each through the task's
//  status (task_wait, or a paused error on its next call).
//

import Foundation
import HarborWeb

extension AgentTaskStore {
    /// Shows the task's tab in `window`, in the Agent space.
    func watch(_ task: AgentTask, in window: BrowserWindowState) {
        guard let tabs = AgentHub.shared.browser?.tabs, let agent = tabs.agentSpaceID,
              tabs.isInAgentSpace(task.itemID) else { return }
        if window.spaceID != agent { tabs.setSpace(agent, in: window) }
        tabs.selectForAgent(task.itemID)
    }

    /// The person drives the tab; the agent's page tools answer "paused" until they hand back.
    func takeOver(_ task: AgentTask, in window: BrowserWindowState) {
        guard !task.isFinished else { return }
        set(task, .personControl)
        watch(task, in: window)
    }

    /// Back to the agent, after a takeover or a step the agent handed over.
    func handBack(_ task: AgentTask) {
        guard task.isPausedForPerson else { return }
        if case .needsYou = task.status { AgentNotifier.withdraw("handoff-\(task.id)") }
        set(task, .running)
    }

    /// Ends the task for good: pending approvals are denied and its recipe runs cancelled.
    func stop(_ task: AgentTask) {
        guard !task.isFinished else { return }
        set(task, .stopped)
        AgentHub.shared.approvals.dropAll(for: task.id)
        for job in AgentHub.shared.jobs.running where job.taskID == task.id {
            AgentHub.shared.jobs.cancel(job)
        }
        AgentNotifier.withdraw("handoff-\(task.id)")
    }
}
