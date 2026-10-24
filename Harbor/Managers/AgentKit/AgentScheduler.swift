// Licensed under GPL-3.0. See LICENSE.
//
//  AgentScheduler.swift
//  Harbor
//
//  Recipes on a schedule and pages watched for changes. One task sleeps until the next one is
//  due; nothing polls. Runs happen in their own Agent space tab with the person's logins, and only
//  while Browser Control is on. A watch notifies the person when the text it watches changes.
//  Saved in Agent/schedules.json.
//

import Foundation
import Observation

@MainActor
@Observable
final class AgentScheduler {
    struct Schedule: Identifiable {
        let id: String
        var recipe: String
        /// Every this many minutes, or daily at `at` ("HH:mm").
        var everyMinutes: Int?
        var at: String?
        var vars: [String: Any]
        var lastRun: Date?
        var lastResult: String?
        var next: Date

        var json: [String: Any] {
            var out: [String: Any] = ["id": id, "recipe": recipe, "vars": vars, "next": iso(next)]
            if let everyMinutes { out["every"] = everyMinutes }
            if let at { out["at"] = at }
            if let lastRun { out["lastRun"] = iso(lastRun) }
            if let lastResult { out["lastResult"] = lastResult }
            return out
        }
    }

    struct Watch: Identifiable {
        let id: String
        var name: String
        var url: String
        var selector: String?
        var everyMinutes: Int
        var hash: String?
        var sample: String?
        var lastChecked: Date?
        var changes: Int
        var next: Date

        var json: [String: Any] {
            var out: [String: Any] = ["id": id, "name": name, "url": url, "every": everyMinutes, "changes": changes, "next": iso(next)]
            if let selector { out["selector"] = selector }
            if let hash { out["hash"] = hash }
            if let sample { out["sample"] = sample }
            if let lastChecked { out["lastChecked"] = iso(lastChecked) }
            return out
        }
    }

    private(set) var schedules: [Schedule] = []
    private(set) var watches: [Watch] = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    /// The job each schedule or watch is running, so a slow one is not started again on top.
    @ObservationIgnored private var running: [String: String] = [:]

    private static var file: URL { AgentHub.directory.appendingPathComponent("schedules.json") }

    // MARK: - Editing

    func addSchedule(recipe: String, everyMinutes: Int?, at: String?, vars: [String: Any]) throws -> Schedule {
        guard AgentHub.shared.recipes.recipe(recipe) != nil else { throw AgentError.invalid("No recipe named \(recipe)") }
        guard (everyMinutes != nil) != (at != nil) else { throw AgentError.invalid("Give either every (minutes) or at (\"HH:mm\")") }
        if let everyMinutes, everyMinutes < 5 { throw AgentError.invalid("every is at least 5 minutes") }
        guard let next = Self.next(everyMinutes: everyMinutes, at: at, after: Date()) else {
            throw AgentError.invalid("at is a time of day such as \"08:30\"")
        }
        let schedule = Schedule(id: AgentID.make("s"), recipe: recipe, everyMinutes: everyMinutes, at: at, vars: vars, next: next)
        schedules.append(schedule)
        changed()
        return schedule
    }

    func addWatch(name: String?, url: String, selector: String?, everyMinutes: Int) throws -> Watch {
        guard let parsed = AgentURLs.web(url) else { throw AgentError.invalid("url must be an http(s) page") }
        guard everyMinutes >= 5 else { throw AgentError.invalid("every is at least 5 minutes") }
        let watch = Watch(id: AgentID.make("w"), name: name ?? parsed.host ?? url, url: parsed.absoluteString, selector: selector,
                          everyMinutes: everyMinutes, changes: 0, next: Date())
        watches.append(watch)
        changed()
        return watch
    }

    func remove(_ id: String) -> Bool {
        let before = schedules.count + watches.count
        schedules.removeAll { $0.id == id }
        watches.removeAll { $0.id == id }
        changed()
        return schedules.count + watches.count < before
    }

    // MARK: - Timing

    /// The next time after `date`: `everyMinutes` later, or the next `at` ("HH:mm") today or tomorrow.
    static func next(everyMinutes: Int?, at: String?, after date: Date) -> Date? {
        if let everyMinutes { return date.addingTimeInterval(Double(everyMinutes) * 60) }
        guard let at, let match = at.wholeMatch(of: #/(\d{1,2}):(\d{2})/#),
              let hour = Int(match.1), let minute = Int(match.2), hour < 24, minute < 60 else { return nil }
        let calendar = Calendar.current
        var parts = calendar.dateComponents([.year, .month, .day], from: date)
        parts.hour = hour
        parts.minute = minute
        guard let today = calendar.date(from: parts) else { return nil }
        return today > date ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    func start() {
        load()
        reschedule()
    }

    private func changed() {
        save()
        reschedule()
    }

    private func reschedule() {
        timer?.cancel()
        let due = (schedules.map(\.next) + watches.map(\.next)).min()
        guard let due else { return }
        timer = Task { @MainActor [weak self] in
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private var enabled: Bool {
        guard let settings = AgentHub.shared.browser?.harborSettings else { return false }
        return settings.developerModeEnabled && settings.browserControlServerEnabled
    }

    private func fire() {
        let now = Date()
        for index in schedules.indices where schedules[index].next <= now {
            let schedule = schedules[index]
            schedules[index].next = Self.next(everyMinutes: schedule.everyMinutes, at: schedule.at, after: now) ?? now.addingTimeInterval(86_400)
            guard enabled, !isRunning(schedule.id) else { continue }
            schedules[index].lastRun = now
            run(schedule)
        }
        for index in watches.indices where watches[index].next <= now {
            watches[index].next = now.addingTimeInterval(Double(watches[index].everyMinutes) * 60)
            guard enabled, !isRunning(watches[index].id) else { continue }
            check(watches[index].id)
        }
        changed()
    }

    private func run(_ schedule: Schedule) {
        do {
            let job = try AgentRecipeRunner.start(name: schedule.recipe, vars: schedule.vars, task: nil)
            running[schedule.id] = job.id
            Task { @MainActor [weak self] in
                await AgentHub.shared.jobs.wait(job, timeout: 3600)
                let ok = job.state == .done
                if let index = self?.schedules.firstIndex(where: { $0.id == schedule.id }) {
                    self?.schedules[index].lastResult = ok ? "done" : "\(job.state.rawValue): \(job.error ?? job.message ?? "")"
                    self?.save()
                }
                if !ok { AgentNotifier.runFinished(title: schedule.recipe, ok: false, detail: job.error ?? job.message ?? job.state.rawValue) }
            }
        } catch {
            AgentNotifier.runFinished(title: schedule.recipe, ok: false, detail: error.agentMessage)
        }
    }

    private func isRunning(_ id: String) -> Bool {
        guard let job = running[id].flatMap(AgentHub.shared.jobs.job) else { return false }
        return !job.state.isFinal
    }

    /// Loads the watched page in its own tab and compares the text it watches with last time.
    @discardableResult
    func check(_ id: String) -> AgentJob? {
        guard let watch = watches.first(where: { $0.id == id }), let browser = AgentHub.shared.browser,
              let url = URL(string: watch.url) else { return nil }
        let job = AgentHub.shared.jobs.start(kind: "watch", title: watch.name) { [weak self] _ in
            // The watch stays on its page's site, whatever the page redirects to.
            guard let item = browser.openAgentTab(url: nil, title: "Watch: \(watch.name)", scope: [url.host ?? ""]) else { throw AgentError.noPage }
            defer { browser.closeAgentTab(item) }
            let webView = try browser.agentWebView(item: item)
            _ = await AgentPageWait.open(webView, url: url, timeout: 30)
            // Client-rendered pages fill in after load.
            try await Task.sleep(for: .seconds(2))
            var args: [String: Any] = [:]
            if let selector = watch.selector { args["target"] = selector }
            let state = try await AgentRuntime.object("textHash", args, in: webView)
            let hash = state["hash"] as? String ?? ""
            let sample = state["sample"] as? String ?? ""
            guard let self, let index = self.watches.firstIndex(where: { $0.id == id }) else { return nil }
            let previous = self.watches[index].hash
            self.watches[index].lastChecked = Date()
            self.watches[index].hash = hash
            self.watches[index].sample = String(sample.prefix(200))
            let changed = previous != nil && previous != hash
            if changed {
                self.watches[index].changes += 1
                AgentNotifier.watchChanged(name: watch.name, detail: String(sample.prefix(140)))
            }
            self.save()
            return ["changed": changed, "first": previous == nil, "hash": hash,
                    "sample": AgentUntrusted.wrap(String(sample.prefix(400)), origin: url.host)]
        }
        running[id] = job.id
        return job
    }

    // MARK: - Storage

    private func load() {
        guard let data = try? Data(contentsOf: Self.file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let now = Date()
        schedules = (json["schedules"] as? [[String: Any]] ?? []).compactMap { s in
            guard let id = s["id"] as? String, let recipe = s["recipe"] as? String else { return nil }
            let every = (s["every"] as? NSNumber)?.intValue
            let at = s["at"] as? String
            let next = (s["next"] as? String).flatMap(parseISO) ?? Self.next(everyMinutes: every, at: at, after: now) ?? now
            return Schedule(id: id, recipe: recipe, everyMinutes: every, at: at, vars: s["vars"] as? [String: Any] ?? [:],
                            lastRun: (s["lastRun"] as? String).flatMap(parseISO), lastResult: s["lastResult"] as? String, next: next)
        }
        watches = (json["watches"] as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w["id"] as? String, let url = w["url"] as? String, let every = (w["every"] as? NSNumber)?.intValue else { return nil }
            return Watch(id: id, name: w["name"] as? String ?? url, url: url, selector: w["selector"] as? String, everyMinutes: every,
                         hash: w["hash"] as? String, sample: w["sample"] as? String,
                         lastChecked: (w["lastChecked"] as? String).flatMap(parseISO), changes: (w["changes"] as? NSNumber)?.intValue ?? 0,
                         next: (w["next"] as? String).flatMap(parseISO) ?? now)
        }
    }

    private func save() {
        let json: [String: Any] = ["schedules": schedules.map(\.json), "watches": watches.map(\.json)]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return }
        try? data.write(to: Self.file, options: .atomic)
    }
}

private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func parseISO(_ string: String) -> Date? { ISO8601DateFormatter().date(from: string) }
