// Licensed under GPL-3.0. See LICENSE.
//
//  AgentHub.swift
//  Harbor
//
//  Owns the agent's state across tools and UI: tasks, jobs, approvals, recipes, schedules,
//  replays and the vault. One instance, configured by BrowserManager at launch, observed by the
//  Agent space's UI.
//

import Foundation
import Observation
import OSLog

@MainActor
@Observable
final class AgentHub {
    static let shared = AgentHub()

    nonisolated static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Harbor", category: "Agent")

    @ObservationIgnored weak var browser: BrowserManager?
    /// Answers Agent space pages (TabsController holds it weakly).
    @ObservationIgnored var pages: AgentPages?

    let tasks = AgentTaskStore()
    let jobs = AgentJobs()
    let approvals = AgentApprovals()
    let replay = AgentReplay()
    let recipes = AgentRecipeStore()
    let scheduler = AgentScheduler()
    let vault = AgentVault()
    let dialogs = AgentDialogLog()
    let recorder = AgentRecorder()

    /// `~/Library/Application Support/<bundle id>/Agent`, made on first use.
    nonisolated static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Harbor", isDirectory: true)
            .appendingPathComponent("Agent", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private init() {}

    func configure(browser: BrowserManager) {
        self.browser = browser
        recipes.load()
        scheduler.start()
        Task.detached(priority: .background) { AgentReplay.pruneOldRuns() }
    }
}

// MARK: - Waiting

/// Lets any number of callers wait, with a timeout, for something to change. `fire()` wakes them
/// all; a waiter whose time runs out wakes with `false`. Replaces polling loops.
@MainActor
final class AgentSignal {
    private final class Waiter {
        var continuation: CheckedContinuation<Bool, Never>?
        var timeout: Task<Void, Never>?
        func resume(_ value: Bool) {
            continuation?.resume(returning: value)
            continuation = nil
            timeout?.cancel()
        }
    }

    private var waiters: [Waiter] = []

    func fire() {
        let woken = waiters
        waiters.removeAll()
        woken.forEach { $0.resume(true) }
    }

    /// True when `fire()` ran before `timeout` seconds passed. A cancelled caller wakes at once
    /// with `false`, so a cancelled job or an abandoned tool call stops waiting.
    func wait(timeout: TimeInterval) async -> Bool {
        guard timeout > 0, !Task.isCancelled else { return false }
        let waiter = Waiter()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                waiters.append(waiter)
                waiter.timeout = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(timeout))
                    self?.drop(waiter)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.drop(waiter) }
        }
    }

    private func drop(_ waiter: Waiter) {
        guard waiter.continuation != nil else { return }
        waiters.removeAll { $0 === waiter }
        waiter.resume(false)
    }

    /// Waits until `condition` holds, re-checking each time the signal fires, for at most `timeout`.
    func wait(until condition: () -> Bool, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            let left = deadline.timeIntervalSinceNow
            guard left > 0, !Task.isCancelled else { return false }
            _ = await wait(timeout: left)
        }
        return true
    }
}

/// Short random ids for tasks, jobs and approvals: easy to read back in a tool call.
enum AgentID {
    static func make(_ prefix: String) -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return prefix + String((0..<6).map { _ in alphabet.randomElement()! })
    }
}

/// Runs `operation` and gives up on it after `seconds`. Not a task group: a group waits for its
/// children even after `cancelAll()`, so work that ignores cancellation (a model reply,
/// `evaluateJavaScript`, a page's own promise) would hold the caller for as long as it took. The
/// two race and the loser is dropped (and cancelled, which work that checks will notice).
@MainActor
enum AgentDeadline {
    private final class Race {
        var done = false
        var work: Task<Void, Never>?
    }

    struct Expired: LocalizedError {
        let seconds: Double
        var errorDescription: String? { "Gave up after \(Int(seconds.rounded())) s" }
    }

    /// The operation's value, or nil when it threw or took longer than `seconds`.
    static func run<T>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async -> T? {
        try? await throwing(seconds, operation)
    }

    /// The operation's value; its own error, or `Expired` when it took longer than `seconds`.
    static func throwing<T>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let race = Race()
        let result: Result<T, Error> = await withCheckedContinuation { continuation in
            // The deadline is made first so the work can cancel it: an answer in a millisecond
            // must not leave a sleeper on the main actor for the full timeout.
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                guard !race.done else { return }
                race.done = true
                race.work?.cancel()
                continuation.resume(returning: .failure(Expired(seconds: seconds)))
            }
            race.work = Task { @MainActor in
                let outcome: Result<T, Error>
                do { outcome = .success(try await operation()) } catch { outcome = .failure(error) }
                guard !race.done else { return }
                race.done = true
                deadline.cancel()
                continuation.resume(returning: outcome)
            }
        }
        return try result.get()
    }
}
