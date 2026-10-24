// Licensed under GPL-3.0. See LICENSE.
//
//  AgentJobs.swift
//  Harbor
//
//  Work that outlasts one tool call (a crawl, a batch of reads, a recipe run). Browser Control
//  answers every call within 30 s, so the tool starts a job and returns its id; the agent follows
//  it with job_status / job_wait / job_cancel. A recipe run can stop at a step it cannot find
//  (needs_repair) and wait for the agent to supply a new target.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgentJob: Identifiable {
    enum State: String {
        case running, needsRepair = "needs_repair", done, failed, cancelled
        var isFinal: Bool { self == .done || self == .failed || self == .cancelled }
    }

    let id: String
    let kind: String
    let title: String
    let taskID: String?
    let started = Date()
    var state: State = .running
    var done = 0
    var total: Int?
    var message: String?
    var result: Any?
    var error: String?
    var finished: Date?
    /// Set while a recipe run waits for a repair: the step and what was tried.
    var repair: [String: Any]?
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored let changed = AgentSignal()
    /// Wakes a run waiting on a repair; the agent's new target rides along.
    @ObservationIgnored let repaired = AgentSignal()
    @ObservationIgnored var repairTarget: String?
    /// An approval the run waits on; cancelling the job denies it, so a late Allow does nothing.
    @ObservationIgnored var pendingApproval: String?

    init(id: String, kind: String, title: String, taskID: String?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.taskID = taskID
    }

    func progress(_ done: Int, of total: Int? = nil, _ message: String? = nil) {
        self.done = done
        if let total { self.total = total }
        if let message { self.message = message }
        changed.fire()
    }

    var summary: [String: Any] {
        var out: [String: Any] = ["job": id, "kind": kind, "title": title, "state": state.rawValue, "done": done]
        if let total { out["total"] = total }
        if let message { out["message"] = message }
        if let error { out["error"] = error }
        if let result { out["result"] = result }
        if let repair { out["repair"] = repair }
        if let taskID { out["task"] = taskID }
        out["seconds"] = Int((finished ?? Date()).timeIntervalSince(started))
        return out
    }
}

@MainActor
@Observable
final class AgentJobs {
    private(set) var all: [AgentJob] = []

    func job(_ id: String) -> AgentJob? { all.first { $0.id == id } }

    var running: [AgentJob] { all.filter { !$0.state.isFinal } }

    /// Starts `work` as a job. Its return value becomes the job's result; a throw fails it.
    @discardableResult
    func start(kind: String, title: String, taskID: String? = nil,
               _ work: @escaping @MainActor (AgentJob) async throws -> Any?) -> AgentJob {
        let job = AgentJob(id: AgentID.make("j"), kind: kind, title: title, taskID: taskID)
        all.append(job)
        trim()
        job.work = Task { @MainActor in
            do {
                let result = try await work(job)
                guard job.state != .cancelled else { return }
                job.result = result
                job.state = .done
            } catch is CancellationError {
                job.state = .cancelled
            } catch {
                if job.state != .cancelled {
                    job.state = .failed
                    job.error = error.agentMessage
                }
            }
            job.finished = Date()
            job.changed.fire()
        }
        return job
    }

    func cancel(_ job: AgentJob) {
        guard !job.state.isFinal else { return }
        job.state = .cancelled
        job.finished = Date()
        job.work?.cancel()
        if let approval = job.pendingApproval { AgentHub.shared.approvals.decide(approval, allow: false) }
        job.repaired.fire()
        job.changed.fire()
    }

    /// Waits until the job finishes or needs a repair, for at most `timeout`.
    func wait(_ job: AgentJob, timeout: TimeInterval) async {
        _ = await job.changed.wait(until: { job.state.isFinal || job.state == .needsRepair }, timeout: timeout)
    }

    /// Finished jobs stay readable for the session; keep the list short.
    private func trim() {
        let finished = all.filter { $0.state.isFinal }
        if finished.count > 50 { all.removeAll { job in finished.prefix(finished.count - 50).contains { $0 === job } } }
    }
}
