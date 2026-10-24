// Licensed under GPL-3.0. See LICENSE.
//
//  AgentApprovals.swift
//  Harbor
//
//  Before a task's action changes something that matters (buying, sending, deleting, signing in,
//  typing a password or card, running a script), the person approves it. Rules from AgentPolicy
//  are the guard; for the rest, the on-device model checks the action against the task's goal from
//  its metadata (what, which control, which site). A control's name is the page's own words, so a
//  page could word a button to look on-goal: the critic is a second look, not the guard. An
//  approved action is remembered for two minutes so a retry goes through.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgentApprovals {
    struct Request: Identifiable {
        let id: String
        let taskID: String
        let taskTitle: String
        let reason: String
        /// What the agent wants to do, for the person: `Click button "Place order" on shop.com`.
        let action: String
        let fingerprint: String
        let created = Date()
    }

    enum Decision: String {
        case allowed, denied
    }

    /// What the gate says about an action.
    enum Gate {
        case allowed
        case needsApproval(Request)
        /// May not happen at all (the task ended or the person has it).
        case refused(String)
    }

    private struct Grant {
        let until: Date
        let singleUse: Bool
    }

    private(set) var pending: [Request] = []
    @ObservationIgnored private var decided: [String: Decision] = [:]
    @ObservationIgnored private var decidedOrder: [String] = []
    @ObservationIgnored private var granted: [String: Grant] = [:]
    @ObservationIgnored let changed = AgentSignal()
    /// Actions the critic found on-goal this session, so it is asked once per action. Only a
    /// real verdict counts: a timeout or a missing model is no answer.
    @ObservationIgnored private var criticCleared: Set<String> = []

    private static let grantLifetime: TimeInterval = 120

    func gate(task: AgentTask, facts: AgentActionFacts) async -> Gate {
        if let refusal = Self.refusal(task) { return .refused(refusal) }
        // The exact control and text: approving one "Place order" approves no other.
        let fingerprint = [task.id, facts.action, facts.element, facts.role, facts.name, facts.host, facts.key,
                           String(facts.text.hashValue)].joined(separator: "|")
        if let grant = granted[fingerprint], grant.until > Date() {
            if grant.singleUse { granted.removeValue(forKey: fingerprint) }
            return .allowed
        }
        if let existing = pending.first(where: { $0.fingerprint == fingerprint }) { return .needsApproval(existing) }

        var reason: String?
        switch task.confirm {
        case .never: return .allowed
        case .always: reason = "Changes the page"
        case .sensitive:
            reason = AgentSensitivity.reason(for: facts)
            if reason == nil, let goal = task.goal, worthACriticCheck(facts), !criticCleared.contains(fingerprint) {
                switch await AgentOnDevice.critic(goal: goal, facts: facts) {
                case .fits: criticCleared.insert(fingerprint)
                case .off(let why): reason = why
                case .unknown: break
                }
            }
        }
        // The person may have stopped the task, or taken it, while the critic thought.
        if let refusal = Self.refusal(task) { return .refused(refusal) }
        guard let reason else { return .allowed }
        let request = Request(id: AgentID.make("a"), taskID: task.id, taskTitle: task.title, reason: reason,
                              action: Self.describe(facts), fingerprint: fingerprint)
        pending.append(request)
        AgentNotifier.approvalNeeded(request)
        changed.fire()
        return .needsApproval(request)
    }

    private static func refusal(_ task: AgentTask) -> String? {
        if task.isFinished { return "Task \(task.id) has ended" }
        if task.isPausedForPerson { return AgentError.paused(task.title).errorDescription }
        return nil
    }

    func decide(_ id: String, allow: Bool) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        let request = pending.remove(at: index)
        decided[id] = allow ? .allowed : .denied
        decidedOrder.append(id)
        if decidedOrder.count > 200 { decided.removeValue(forKey: decidedOrder.removeFirst()) }
        if allow {
            let grant = Grant(until: Date().addingTimeInterval(Self.grantLifetime), singleUse: AgentSensitivity.isSingleUse(request.reason))
            granted[request.fingerprint] = grant
        }
        AgentNotifier.withdraw(request.id)
        changed.fire()
    }

    /// Denies what a task still waits on, when it ends.
    func dropAll(for taskID: String) {
        for request in pending where request.taskID == taskID { decide(request.id, allow: false) }
    }

    func decision(_ id: String) -> Decision? { decided[id] }

    func isKnown(_ id: String) -> Bool { decided[id] != nil || pending.contains { $0.id == id } }

    /// Waits for the person's answer, at most `timeout`. Nil while still pending.
    func wait(_ id: String, timeout: TimeInterval) async -> Decision? {
        _ = await changed.wait(until: { self.decided[id] != nil }, timeout: timeout)
        return decided[id]
    }

    /// Clicks on named buttons and links, submits and leaving for another site: the actions that
    /// can do something the person did not ask for. Typing and scrolling alone cannot.
    private func worthACriticCheck(_ facts: AgentActionFacts) -> Bool {
        switch facts.action {
        case "click", "submit", "press": return !facts.name.isEmpty || facts.action == "submit" || facts.element.isEmpty
        case "navigate": return true
        default: return false
        }
    }

    static func describe(_ facts: AgentActionFacts) -> String {
        let verb: String
        switch facts.action {
        case "click": verb = "Click"
        case "fill", "type", "setValue": verb = "Type into"
        case "submit": verb = "Submit"
        case "press": verb = "Press \(facts.key.isEmpty ? "a key" : facts.key) in"
        case "select": verb = "Choose in"
        case "check": verb = "Tick"
        case "uncheck": verb = "Untick"
        case "navigate": return "Open \(facts.host.isEmpty ? facts.url : facts.host)"
        case "upload": return "Upload a file to \(facts.host)"
        default: verb = facts.action.capitalized
        }
        let what = facts.name.isEmpty ? (facts.role.isEmpty ? "the page" : facts.role) : "\(facts.role) \"\(facts.name)\""
        return "\(verb) \(what)" + (facts.host.isEmpty ? "" : " on \(facts.host)")
    }
}
