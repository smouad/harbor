// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Page.swift
//  Harbor
//
//  Seeing and driving a page: observe, act, read, upload, screenshot, dialogs. The same contract
//  as Browser Bridge's snapshot/act/read/upload/screenshot, so its CLI and recipes run on Harbor.
//

import AppKit
import Foundation
import WebKit

extension AgentToolbox {
    static let pageTools: [AgentTool] = [observe, act, read, upload, screenshot, dialogs]

    // MARK: - observe

    private static let observe = AgentTool(
        "observe",
        "The page's visible interactive elements with refs (e1, e2, …) for act. A ref stays the same for an element while it exists. Returns url, title, viewport and elements: ref, role, name, tag, type, value, href, checked, disabled, x, y, w, h, offscreen.",
        properties: [
            "filter": ["type": "string", "description": "Only elements whose role, name, value or link contains this text"],
            "limit": ["type": "integer", "description": "At most this many elements (default 150)"]
        ]
    ) { call in
        let webView = try call.page()
        let result = try await AgentRuntime.object("observe", [
            "filter": call.args.string("filter") ?? "", "limit": min(max(call.args.int("limit") ?? 150, 1), 1000)
        ], in: webView)
        return .untrusted(result, origin: webView.url?.host)
    }

    // MARK: - act

    private static let act = AgentTool(
        "act",
        """
        Run browser steps in order and stop at the first failure (continueOnError to go on). Each step: {action, target, …}. \
        Actions: click, fill (replace text), type (append), setValue, select (value or label), check, uncheck, press (key: Enter, Tab, Escape, ArrowDown, Meta+a…), \
        hover, focus, scrollIntoView, scroll (target top|bottom or deltaY px), mouseMove (x, y), waitFor (target appears; state: hidden to wait for it to go), \
        waitForUrl (url substring or /regex/), submit, getText, getValue, eval (code: async function body, arg, as: bind for later ${vars.name}), \
        navigate (url), back, forward, reload. Targets: a ref from observe, CSS, xpath=…, text=…, role=button[name="Save"]. \
        Clicks and keys are real native events (input: "dom" for synthetic); human: true moves the pointer along a path with pauses; force: true clicks even when something covers the target. \
        Typing goes through the page's editor as trusted input. Text may hold {{secret:name}} for a vault secret allowed on the site. \
        In a task, an action that buys, sends, deletes, signs in or seems off-goal answers with an approval id: call approval_wait, then send the remaining steps again.
        """,
        properties: [
            "actions": ["type": "array", "items": ["type": "object"], "description": "Steps to run"],
            "continueOnError": ["type": "boolean"],
            "snapshot": ["type": "boolean", "description": "Also return observe's elements after the steps"]
        ],
        required: ["actions"]
    ) { call in
        let webView = try call.page()
        guard let steps = call.args.objects("actions"), !steps.isEmpty else { throw AgentError.invalid("actions must be a list of steps") }
        let actions = AgentActions(webView: webView, task: call.task, deadline: call.deadline.addingTimeInterval(-1))
        let continueOnError = call.args.bool("continueOnError") ?? false
        var results: [[String: Any]] = []
        var ok = true
        var approval: String?
        for (i, step) in steps.enumerated() {
            let action = step["action"] as? String ?? ""
            var entry: [String: Any] = ["i": i, "action": action]
            do {
                if let value = try await actions.perform(step) { entry["value"] = value }
                entry["ok"] = true
            } catch AgentActions.StepError.needsApproval(let id, let reason) {
                entry["ok"] = false
                entry["needs_approval"] = id
                entry["reason"] = reason
                approval = id
                ok = false
                results.append(entry)
                break
            } catch {
                entry["ok"] = false
                entry["error"] = error.agentMessage
                ok = false
                results.append(entry)
                if !continueOnError { break }
                continue
            }
            results.append(entry)
        }
        var out: [String: Any] = ["ok": ok, "results": results, "url": webView.url?.absoluteString ?? ""]
        if let approval { out["needs_approval"] = approval }
        if !actions.vars.isEmpty { out["vars"] = actions.vars }
        if call.args.bool("snapshot") == true,
           let elements = try? await AgentRuntime.object("observe", ["limit": 150], in: webView)["elements"] {
            out["elements"] = elements
        }
        // Values, errors and the URL all come from the page.
        let result = AgentResult.untrusted(out, origin: webView.url?.host)
        return ok ? result : AgentResult(content: result.content, isError: approval == nil)
    }

    // MARK: - read

    private static let read = AgentTool(
        "read",
        "The page as clean Markdown (main content, headings, links, lists, tables, code). With url, opens it first in the same tab. With urls (a list), starts a job that reads each in turn; follow it with job_wait. selector reads one part of the page; links: true adds the page's links.",
        properties: [
            "url": ["type": "string"],
            "urls": ["type": "array", "items": ["type": "string"]],
            "selector": ["type": "string"],
            "links": ["type": "boolean"],
            "maxLength": ["type": "integer", "description": "Characters of Markdown (default 40000)"],
            "dir": ["type": "string", "description": "With urls: also write each page to this folder under ~/Downloads/Harbor MCP"]
        ]
    ) { call in
        var options: [String: Any] = ["links": call.args.bool("links") ?? false, "maxLength": call.args.int("maxLength") ?? 40_000]
        if let selector = call.args.string("selector") { options["selector"] = selector }
        if let list = call.args.strings("urls"), call.args.raw["urls"] != nil {
            let urls = try list.map { try webURL($0, task: call.task) }
            let dir = try call.args.string("dir").map(outputDirectory)
            let scope = call.task?.allowedOrigins ?? []
            let job = AgentHub.shared.jobs.start(kind: "read", title: "Read \(urls.count) pages", taskID: call.task?.id) { job in
                try await readPages(urls, options: options, dir: dir, scope: scope, job: job, browser: call.browser)
            }
            return .json(job.summary)
        }
        let webView: WKWebView
        if let string = call.args.string("url") {
            let url = try webURL(string, task: call.task)
            if let existing = call.webView {
                webView = existing
            } else {
                // No Agent space tab yet: make one.
                guard let item = call.browser.openAgentTab(url: nil, title: nil) else { throw AgentError.noPage }
                call.browser.tabs.selectForAgent(item)
                webView = try call.browser.agentWebView(item: item)
            }
            _ = await AgentPageWait.open(webView, url: url, timeout: call.waitBudget(nil, fallback: 20))
        } else {
            webView = try call.page()
        }
        let page = try await AgentRuntime.object("markdown", options, in: webView)
        return .untrusted(page, origin: webView.url?.host)
    }

    /// Reads each URL in a job's own tab; pages go to the job's result, or to files when `dir` is set.
    static func readPages(_ urls: [URL], options: [String: Any], dir: URL?, scope: [String], job: AgentJob, browser: BrowserManager) async throws -> Any {
        guard let item = browser.openAgentTab(url: nil, title: job.title, scope: scope) else { throw AgentError.noPage }
        defer { browser.closeAgentTab(item) }
        var pages: [[String: Any]] = []
        var index: [String] = []
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            job.progress(i, of: urls.count, url.absoluteString)
            let webView = try browser.agentWebView(item: item)
            _ = await AgentPageWait.open(webView, url: url, timeout: 30)
            do {
                var page = try await AgentRuntime.object("markdown", options, in: webView)
                if let dir {
                    let file = dir.appendingPathComponent(String(format: "%03d-%@.md", i + 1, slug(url)))
                    try ((page["markdown"] as? String) ?? "").write(to: file, atomically: true, encoding: .utf8)
                    index.append(AgentJSON.compact(["url": url.absoluteString, "title": page["title"] ?? "", "file": file.lastPathComponent]))
                    page = ["url": url.absoluteString, "title": page["title"] ?? "", "file": file.path]
                } else {
                    page["markdown"] = AgentUntrusted.wrap(page["markdown"] as? String ?? "", origin: url.host)
                }
                pages.append(page)
            } catch {
                pages.append(["url": url.absoluteString, "error": error.agentMessage])
            }
        }
        if let dir { try (index.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("index.jsonl"), atomically: true, encoding: .utf8) }
        job.progress(urls.count, of: urls.count, "Done")
        return ["pages": pages]
    }

    // MARK: - upload

    private static let upload = AgentTool(
        "upload",
        "Put files into a file input (or the file input inside a drop zone) as if the person picked them. files are paths relative to ~/Downloads/Harbor MCP; Harbor reads nothing outside that folder. Uses the page's own file picker, so change events and validation run as for a person.",
        properties: [
            "target": ["type": "string", "description": "The file input, a ref or selector; or an element containing one"],
            "files": ["type": "array", "items": ["type": "string"]]
        ],
        required: ["target", "files"]
    ) { call in
        let webView = try call.page()
        let target = try call.args.required("target")
        let files = try (call.args.strings("files") ?? []).map { path -> URL in
            guard let url = DevMCPFiles.resolve(path), FileManager.default.fileExists(atPath: url.path) else {
                throw AgentError.invalid("\(path) is not a file inside \(DevMCPFiles.root.path)")
            }
            return url
        }
        guard !files.isEmpty, let item = call.session?.itemID else { throw AgentError.invalid("files is empty") }
        let input = try await AgentRuntime.object("fileInput", ["target": target], in: webView)
        guard let ref = input["ref"] as? String else { throw AgentError.invalid("No file input found") }
        if let task = call.task, task.confirm != .never {
            var facts = AgentActionFacts(action: "upload")
            facts.host = webView.url?.host ?? ""
            if let pending = await AgentHub.shared.approvals.gate(task: task, facts: facts) {
                return .json(["ok": false, "needs_approval": pending.id, "reason": pending.reason])
            }
        }
        AgentHub.shared.dialogs.stage(files, for: item)
        // Opening a file picker needs a user gesture; script from Browser Control carries one.
        _ = try await webView.callAsyncJavaScript(
            "const el = await globalThis.__harborAgent.call('resolveRef', {ref}); try { el.showPicker(); } catch { el.click(); } return true",
            arguments: ["ref": ref], contentWorld: AgentRuntime.world)
        // The picker answers synchronously; the change event follows.
        try await Task.sleep(for: .milliseconds(300))
        let chosen = try await webView.callAsyncJavaScript(
            "const el = await globalThis.__harborAgent.call('resolveRef', {ref}); return [...(el.files || [])].map(f => f.name)",
            arguments: ["ref": ref], contentWorld: AgentRuntime.world) as? [String] ?? []
        _ = AgentHub.shared.dialogs.takeStaged(for: item)
        guard !chosen.isEmpty else { throw AgentError.invalid("The page did not take the files") }
        return .json(["ok": true, "files": chosen, "input": ref])
    }

    // MARK: - screenshot

    private static let screenshot = AgentTool(
        "screenshot",
        "JPEG of the page. fullPage: the whole page, not just what is on screen. marks: box each interactive element and label it with its ref, and list the refs, so what you see matches observe and act.",
        properties: [
            "maxWidth": ["type": "integer", "description": "Pixels (default 1200)"],
            "fullPage": ["type": "boolean"],
            "marks": ["type": "boolean"]
        ]
    ) { call in
        let webView = try call.page()
        let maxWidth = CGFloat(min(max(call.args.int("maxWidth") ?? 1200, 200), 4000))
        if call.args.bool("fullPage") == true {
            let image = try await AgentPerception.fullPage(webView, maxWidth: maxWidth)
            guard let jpeg = AgentImages.jpeg(image) else { throw AgentError.invalid("Encoding failed") }
            return .image(jpeg: jpeg)
        }
        let image = try await AgentPerception.visible(webView, maxWidth: maxWidth)
        guard call.args.bool("marks") == true else {
            guard let jpeg = AgentImages.jpeg(image) else { throw AgentError.invalid("Encoding failed") }
            return .image(jpeg: jpeg)
        }
        let marks = try await AgentRuntime.call("marks", in: webView) as? [[String: Any]] ?? []
        let viewport = try await AgentRuntime.object("point", ["x": 0, "y": 0], in: webView)["viewport"] as? [String: Any]
        let width = (viewport?["w"] as? NSNumber)?.doubleValue ?? Double(webView.bounds.width)
        let marked = AgentPerception.marked(image, elements: marks, viewportWidth: width)
        guard let jpeg = AgentImages.jpeg(marked) else { throw AgentError.invalid("Encoding failed") }
        let legend = marks.map { "\($0["ref"] ?? "") \($0["role"] ?? "") \"\($0["name"] ?? "")\"" }.joined(separator: "\n")
        return AgentResult.image(jpeg: jpeg).appending(.untrusted(legend, origin: webView.url?.host))
    }

    // MARK: - dialogs

    private static let dialogs = AgentTool(
        "dialogs",
        "JavaScript alerts, confirms and prompts the page opened, and how they were answered (agent pages answer at once: alert ok, confirm and prompt dismissed). accept/promptText set the answer for the next ones on this page.",
        properties: [
            "since": ["type": "integer", "description": "Cursor from the last call, for newer entries only"],
            "accept": ["type": "boolean", "description": "Accept confirms and prompts from now on"],
            "promptText": ["type": "string"]
        ]
    ) { call in
        guard let item = call.session?.itemID else { throw AgentError.noPage }
        let log = AgentHub.shared.dialogs
        if call.args.raw["accept"] != nil || call.args.raw["promptText"] != nil {
            log.setPolicy(.init(accept: call.args.bool("accept") ?? false, promptText: call.args.string("promptText")), for: item)
        }
        let entries = log.entries(for: item, since: call.args.int("since") ?? 0).map { e -> [String: Any] in
            ["kind": e.kind.rawValue, "message": e.message, "answer": e.answer, "url": e.url, "seq": e.seq]
        }
        return .untrusted(["entries": entries, "cursor": log.cursor], origin: call.webView?.url?.host)
    }

    // MARK: - Helpers

    static func webURL(_ string: String, task: AgentTask?) throws -> URL {
        guard let url = AgentURLs.web(string) else { throw AgentError.invalid("\(string) is not an http(s) URL") }
        if let task, !task.allows(url) { throw AgentError.outOfScope(url.host ?? string) }
        return url
    }

    static func outputDirectory(_ relative: String) throws -> URL {
        guard let dir = DevMCPFiles.resolve(relative) else {
            throw AgentError.invalid("dir must be a relative path inside \(DevMCPFiles.root.path)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func slug(_ url: URL) -> String {
        let raw = (url.host ?? "") + url.path
        let allowed = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(allowed).split(separator: "-").joined(separator: "-")
        return String(collapsed.prefix(60)).isEmpty ? "page" : String(collapsed.prefix(60))
    }
}
