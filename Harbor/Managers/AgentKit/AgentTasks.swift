// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTasks.swift
//  Harbor
//
//  A task is one job an agent does for the person, in its own Agent space tab: a title, an
//  optional goal (what the action critic checks actions against), the sites it may open, and a
//  status the person can see and change. The person can take over at any time, and the agent can
//  hand over for a step only they can do (a login, a code, a CAPTCHA) and wait to get it back.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgentTask: Identifiable {
    enum Status: Equatable {
        case running
        /// The agent asked the person to do something and waits.
        case needsYou(String)
        /// The person took the controls.
        case personControl
        case done(String?)
        case failed(String?)
        /// The person stopped it.
        case stopped

        var name: String {
            switch self {
            case .running: "running"
            case .needsYou: "needs_you"
            case .personControl: "person_control"
            case .done: "done"
            case .failed: "failed"
            case .stopped: "stopped"
            }
        }
    }

    /// When an action needs the person's approval.
    enum ConfirmPolicy: String {
        /// Purchases, sends, deletes, sign-ins and anything the critic finds off-goal.
        case sensitive
        /// Every action that changes the page.
        case always
        /// Never ask (the person's own scripted runs).
        case never
    }

    let id: String
    let title: String
    let goal: String?
    let itemID: UUID
    let allowedOrigins: [String]
    let confirm: ConfirmPolicy
    let startedAt = Date()
    var status: Status = .running
    var note: String?
    var steps = 0
    var lastURL: String?
    var endedAt: Date?

    init(id: String, title: String, goal: String?, itemID: UUID, allowedOrigins: [String], confirm: ConfirmPolicy) {
        self.id = id
        self.title = title
        self.goal = goal
        self.itemID = itemID
        self.allowedOrigins = allowedOrigins
        self.confirm = confirm
    }

    var isPausedForPerson: Bool {
        switch status {
        case .needsYou, .personControl: true
        default: false
        }
    }

    var isFinished: Bool {
        switch status {
        case .done, .failed, .stopped: true
        default: false
        }
    }

    /// Whether the task may load `url` in its tab. No list means anywhere.
    func allows(_ url: URL) -> Bool {
        AgentScope.allows(url, origins: allowedOrigins)
    }

    var summary: [String: Any] {
        var out: [String: Any] = ["task": id, "title": title, "status": status.name, "steps": steps]
        if let goal { out["goal"] = goal }
        if !allowedOrigins.isEmpty { out["allowedOrigins"] = allowedOrigins }
        if case .needsYou(let reason) = status { out["reason"] = reason }
        if case .done(let s) = status, let s { out["summary"] = s }
        if case .failed(let s) = status, let s { out["summary"] = s }
        if let note { out["note"] = note }
        if let lastURL { out["url"] = lastURL }
        return out
    }
}

@MainActor
@Observable
final class AgentTaskStore {
    private(set) var all: [AgentTask] = []
    @ObservationIgnored let changed = AgentSignal()

    var active: [AgentTask] { all.filter { !$0.isFinished } }

    var needingPerson: [AgentTask] { all.filter { if case .needsYou = $0.status { true } else { false } } }

    func task(_ id: String) -> AgentTask? { all.first { $0.id == id } }

    func task(forItem itemID: UUID) -> AgentTask? { all.last { $0.itemID == itemID && !$0.isFinished } }

    func add(_ task: AgentTask) {
        all.append(task)
        // Ended tasks stay listed for the session; keep the list short, and their tabs with it.
        let finished = all.filter(\.isFinished)
        if finished.count > 30, let oldest = finished.first { remove([oldest]) }
        changed.fire()
    }

    /// Takes ended tasks off the list and closes their tabs.
    func clearFinished() {
        remove(all.filter(\.isFinished))
        changed.fire()
    }

    private func remove(_ tasks: [AgentTask]) {
        for task in tasks {
            all.removeAll { $0 === task }
            AgentHub.shared.browser?.closeAgentTab(task.itemID)
        }
    }

    func set(_ task: AgentTask, _ status: AgentTask.Status) {
        guard task.status != status else { return }
        task.status = status
        if task.isFinished { task.endedAt = Date() }
        changed.fire()
    }
}
