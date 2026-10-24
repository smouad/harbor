// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+LinkedIn.swift
//  Harbor
//
//  LinkedIn people search and profile reading, Browser Bridge's `search` and `profile` jobs: one
//  Agent space tab kept for LinkedIn (its logins are the person's, borrowed like every agent tab),
//  limited to linkedin.com, reading at a person's pace. What keeps an account safe is low volume,
//  so Harbor refuses past 30 profiles a day and 10 searches an hour instead of slowing down.
//

import Foundation
import WebKit

extension AgentToolbox {
    static let linkedInTools: [AgentTool] = [linkedInSearch, linkedInProfile]

    private static let linkedInSearch = AgentTool(
        "linkedin_search",
        "LinkedIn people search: name, headline, location, profile URL and connection degree of each result, over pages (default 1, at most 3). Uses the person's LinkedIn login. At most 10 searches an hour. Answers within 20 s or with a job id for job_wait.",
        page: .none,
        properties: ["query": ["type": "string"], "pages": ["type": "integer"]],
        required: ["query"]
    ) { call in
        let query = try call.args.required("query")
        let pages = min(max(call.args.int("pages") ?? 1, 1), 3)
        try AgentLinkedIn.usage.claim(.search)
        let job = AgentHub.shared.jobs.start(kind: "linkedin_search", title: "LinkedIn: \(query)") { job in
            try await AgentLinkedIn.oneAtATime {
                ["hits": try await AgentLinkedIn.search(query, pages: pages, job: job, browser: call.browser)]
            }
        }
        await AgentHub.shared.jobs.wait(job, timeout: min(20, call.remaining - 2))
        return .job(job)
    }

    private static let linkedInProfile = AgentTool(
        "linkedin_profile",
        "A LinkedIn profile's top card and latest post: name, headline, location, followers, connections, current company and school. target is a profile URL, a /in/ slug, or a name (its first search result, which counts as a search). Uses the person's LinkedIn login. At most 30 profiles a day. Answers within 20 s or with a job id for job_wait.",
        page: .none,
        properties: ["target": ["type": "string"]],
        required: ["target"]
    ) { call in
        let target = try call.args.required("target").trimmingCharacters(in: .whitespaces)
        let byName = AgentLinkedIn.profileURL(target) == nil
        if byName { try AgentLinkedIn.usage.claim(.search) }
        try AgentLinkedIn.usage.claim(.profile)
        let job = AgentHub.shared.jobs.start(kind: "linkedin_profile", title: "LinkedIn: \(target)") { job in
            try await AgentLinkedIn.oneAtATime {
                try await AgentLinkedIn.profile(target, job: job, browser: call.browser)
            }
        }
        await AgentHub.shared.jobs.wait(job, timeout: min(20, call.remaining - 2))
        return .job(job)
    }
}

@MainActor
enum AgentLinkedIn {
    static let usage = AgentLinkedInUsage(file: AgentHub.directory.appendingPathComponent("linkedin-usage.json"))

    private static let script: String = {
        guard let url = Bundle.main.url(forResource: "agent-linkedin", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("agent-linkedin.js is missing from the app bundle")
        }
        return source
    }()

    /// The Agent space tab LinkedIn work happens in, kept between calls.
    private static var tab: UUID?
    /// The latest LinkedIn job: each waits for the one before, since they share the tab.
    private static var queue: Task<Void, Never>?

    static func oneAtATime<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = queue
        let mine = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        queue = Task { @MainActor in _ = try? await mine.value }
        return try await withTaskCancellationHandler {
            try await mine.value
        } onCancel: {
            mine.cancel()
        }
    }

    static func search(_ query: String, pages: Int, job: AgentJob, browser: BrowserManager) async throws -> [[String: Any]] {
        var hits: [[String: Any]] = []
        var seen = Set<String>()
        for page in 1...pages {
            job.progress(page - 1, of: pages, "Page \(page)")
            var components = URLComponents(string: "https://www.linkedin.com/search/results/people/")!
            components.queryItems = [URLQueryItem(name: "keywords", value: query)]
                + (page > 1 ? [URLQueryItem(name: "page", value: String(page))] : [])
            let found = try await run("scrapeSearch", at: components.url!, browser: browser)
            for hit in found["hits"] as? [[String: Any]] ?? [] {
                let key = hit["profileUrl"] as? String ?? hit["name"] as? String ?? ""
                if !key.isEmpty, seen.insert(key).inserted { hits.append(hit) }
            }
            if page < pages { try await Task.sleep(for: .seconds(Double.random(in: 2...4))) }
        }
        return hits
    }

    static func profile(_ target: String, job: AgentJob, browser: BrowserManager) async throws -> [String: Any] {
        var url = profileURL(target)
        if url == nil {
            job.progress(0, of: 2, "Looking up \(target)")
            let first = try await search(target, pages: 1, job: job, browser: browser).first { $0["profileUrl"] is String }
            guard let found = first?["profileUrl"] as? String else { throw AgentError.invalid("No LinkedIn profile found for \(target)") }
            url = URL(string: found)
        }
        job.progress(1, of: 2, "Reading the profile")
        let read = try await run("scrapeProfile", at: url!, browser: browser)
        return read["profile"] as? [String: Any] ?? [:]
    }

    /// `https://www.linkedin.com/in/<slug>/` for a URL or slug; nil for a name.
    static func profileURL(_ target: String) -> URL? {
        if let match = target.firstMatch(of: #/\/in\/([^\/?#]+)/#) {
            return URL(string: "https://www.linkedin.com/in/\(match.1)/")
        }
        guard !target.contains(where: \.isWhitespace), !target.lowercased().hasPrefix("http"),
              let slug = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "https://www.linkedin.com/in/\(slug)/")
    }

    /// Opens `url` in the LinkedIn tab and runs one of agent-linkedin.js's functions there.
    private static func run(_ function: String, at url: URL, browser: BrowserManager) async throws -> [String: Any] {
        let webView = try webView(browser)
        guard await AgentPageWait.open(webView, url: url, timeout: 30) else {
            throw AgentError.invalid("LinkedIn did not load \(url.absoluteString)")
        }
        try checkSignedIn(webView)
        _ = try browser.agentWebView(item: tab!)
        let result = try await webView.callAsyncJavaScript(script + "\nreturn await \(function)();", contentWorld: AgentRuntime.world)
        // The wall can also arrive by a redirect after the page loaded.
        try checkSignedIn(webView)
        guard let object = result as? [String: Any] else { throw AgentError.invalid("LinkedIn's page gave nothing back") }
        if let error = object["error"] as? String { throw AgentError.invalid(error) }
        return object
    }

    /// A signed-out visit lands on a login, sign-up or checkpoint page.
    private static func checkSignedIn(_ webView: WKWebView) throws {
        let path = webView.url?.path ?? ""
        let walls = ["/login", "/uas/login", "/authwall", "/signup", "/checkpoint"]
        guard walls.contains(where: { path.hasPrefix($0) }) else { return }
        throw AgentError.invalid("LinkedIn asks to sign in. Sign in to LinkedIn in the space the Agent space borrows logins from, then try again.")
    }

    private static func webView(_ browser: BrowserManager) throws -> WKWebView {
        if let tab, browser.tabs.item(tab) != nil {
            return try browser.agentWebView(item: tab)
        }
        guard let opened = browser.openAgentTab(url: nil, title: "LinkedIn", scope: ["linkedin.com"]) else { throw AgentError.noPage }
        tab = opened
        return try browser.agentWebView(item: opened)
    }
}
