// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Jobs.swift
//  Harbor
//
//  Long work as jobs: crawl, and following any job (jobs, job_status, job_wait, job_cancel).
//

import Foundation
import WebKit

extension AgentToolbox {
    static let jobTools: [AgentTool] = [crawl, jobs, jobStatus, jobWait, jobCancel]

    private static let crawl = AgentTool(
        "crawl",
        "Read a page and the pages it links to, breadth first, as Markdown files in dir (under ~/Downloads/Harbor MCP) plus dir/index.jsonl. Runs as a job in its own Agent space tab; follow it with job_wait.",
        page: .none,
        properties: [
            "url": ["type": "string"],
            "limit": ["type": "integer", "description": "Pages to read (default 20, at most 200)"],
            "sameHost": ["type": "boolean", "description": "Only follow links on the start page's host (default true)"],
            "dir": ["type": "string"],
            "task": ["type": "string", "description": "Task whose allowed sites limit the crawl"]
        ],
        required: ["url", "dir"]
    ) { call in
        let task = try call.args.string("task").map { id -> AgentTask in
            guard let task = AgentHub.shared.tasks.task(id) else { throw AgentError.unknownTask(id) }
            return task
        }
        let start = try webURL(try call.args.required("url"), task: task)
        let dir = try outputDirectory(try call.args.required("dir"))
        let limit = min(max(call.args.int("limit") ?? 20, 1), 200)
        let sameHost = call.args.bool("sameHost") ?? true
        let browser = call.browser
        let job = AgentHub.shared.jobs.start(kind: "crawl", title: "Crawl \(start.host ?? "")", taskID: task?.id) { job in
            try await crawlPages(from: start, limit: limit, sameHost: sameHost, dir: dir, task: task, job: job, browser: browser)
        }
        return .json(job.summary)
    }

    private static func crawlPages(from start: URL, limit: Int, sameHost: Bool, dir: URL, task: AgentTask?,
                                   job: AgentJob, browser: BrowserManager) async throws -> Any {
        guard let item = browser.openAgentTab(url: nil, title: job.title, scope: task?.allowedOrigins ?? []) else { throw AgentError.noPage }
        defer { browser.closeAgentTab(item) }
        var queue = [start]
        var seen: Set<String> = [key(start)]
        var index: [String] = []
        var read = 0
        while !queue.isEmpty, read < limit {
            try Task.checkCancellation()
            let url = queue.removeFirst()
            job.progress(read, of: limit, url.absoluteString)
            let webView = try browser.agentWebView(item: item)
            _ = await AgentPageWait.open(webView, url: url, timeout: 30)
            guard let page = try? await AgentRuntime.object("markdown", ["links": true, "maxLength": 200_000], in: webView) else {
                index.append(AgentJSON.compact(["url": url.absoluteString, "error": "unreadable"]))
                continue
            }
            read += 1
            let file = dir.appendingPathComponent(String(format: "%03d-%@.md", read, slug(url)))
            let title = page["title"] as? String ?? ""
            try "# \(title)\n\n<\(url.absoluteString)>\n\n\(page["markdown"] as? String ?? "")".write(to: file, atomically: true, encoding: .utf8)
            index.append(AgentJSON.compact(["url": url.absoluteString, "title": title, "file": file.lastPathComponent]))
            for link in page["links"] as? [[String: Any]] ?? [] {
                guard let href = link["href"] as? String, let next = URL(string: href),
                      next.scheme?.hasPrefix("http") == true, seen.insert(key(next)).inserted else { continue }
                if sameHost, next.host != start.host { continue }
                if let task, !task.allows(next) { continue }
                queue.append(next)
            }
        }
        try (index.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("index.jsonl"), atomically: true, encoding: .utf8)
        job.progress(read, of: read, "Done")
        return ["pages": read, "dir": dir.path, "index": dir.appendingPathComponent("index.jsonl").path]
    }

    /// One entry per page: no fragment, no trailing slash difference.
    private static func key(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        var string = components?.string ?? url.absoluteString
        if string.hasSuffix("/") { string.removeLast() }
        return string
    }

    // MARK: - Following jobs

    private static let jobs = AgentTool("jobs", "Jobs this session, newest last, with state and progress.", page: .none) { _ in
        // Without results: those come from pages, and job_status shows one job's.
        .json(AgentHub.shared.jobs.all.map { $0.summary.filter { $0.key != "result" && $0.key != "repair" } })
    }

    private static let jobStatus = AgentTool(
        "job_status", "A job's state (running, needs_repair, done, failed, cancelled), progress and, when done, its result.",
        page: .none, properties: ["job": ["type": "string"]], required: ["job"]
    ) { call in
        .job(try job(call))
    }

    private static let jobWait = AgentTool(
        "job_wait", "Wait up to timeout seconds (default and most 25) for a job to finish or need a repair, then return its status. Call again while it is still running.",
        page: .none, properties: ["job": ["type": "string"], "timeout": ["type": "number"]], required: ["job"]
    ) { call in
        let job = try job(call)
        await AgentHub.shared.jobs.wait(job, timeout: min(call.args.double("timeout") ?? 25, call.remaining - 1))
        return .job(job)
    }

    private static let jobCancel = AgentTool(
        "job_cancel", "Stop a job.", page: .none, properties: ["job": ["type": "string"]], required: ["job"]
    ) { call in
        let job = try job(call)
        AgentHub.shared.jobs.cancel(job)
        return .job(job)
    }

    private static func job(_ call: AgentCall) throws -> AgentJob {
        let id = try call.args.required("job")
        guard let job = AgentHub.shared.jobs.job(id) else { throw AgentError.invalid("No job \(id). jobs lists them.") }
        return job
    }
}
