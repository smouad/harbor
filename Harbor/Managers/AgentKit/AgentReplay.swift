// Licensed under GPL-3.0. See LICENSE.
//
//  AgentReplay.swift
//  Harbor
//
//  Every tool call a task makes, kept as a step with what it did, how it ended, the page it was
//  on and, after a step that changes the page, a small picture of it. Written to
//  Agent/runs/<task id>/steps.jsonl and <n>.jpg so a run can be scrubbed through afterwards, and
//  kept in memory for the replay viewer.
//

import AppKit
import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class AgentReplay {
    struct Step: Identifiable {
        let id: Int
        let date: Date
        let tool: String
        let detail: String
        let ok: Bool
        let summary: String
        let url: String?
        let milliseconds: Int
        var frame: URL?

        var json: [String: Any] {
            var out: [String: Any] = ["i": id, "at": ISO8601DateFormatter().string(from: date), "tool": tool,
                                      "detail": detail, "ok": ok, "summary": summary, "ms": milliseconds]
            if let url { out["url"] = url }
            if let frame { out["frame"] = frame.lastPathComponent }
            return out
        }
    }

    /// Tools that change the page, so their step gets a picture.
    private static let changesPage: Set<String> = ["act", "read", "upload", "site_tool_call", "task_start"]

    /// Runs older than this are deleted at launch.
    private static let keepRuns: TimeInterval = 14 * 86_400

    /// Deletes the folders of runs that ended long ago.
    nonisolated static func pruneOldRuns() {
        let runs = AgentHub.directory.appendingPathComponent("runs", isDirectory: true)
        let cutoff = Date().addingTimeInterval(-keepRuns)
        let folders = (try? FileManager.default.contentsOfDirectory(at: runs, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            if modified < cutoff { try? FileManager.default.removeItem(at: folder) }
        }
    }

    private(set) var steps: [String: [Step]] = [:]

    static func directory(for taskID: String) -> URL {
        AgentHub.directory.appendingPathComponent("runs/\(taskID)", isDirectory: true)
    }

    func steps(for task: AgentTask) -> [Step] { steps[task.id] ?? [] }

    func record(task: AgentTask, tool: String, args: [String: Any], result: AgentResult, started: Date, webView: WKWebView?) {
        var list = steps[task.id] ?? []
        let text = result.content.compactMap { $0["text"] as? String }.joined(separator: "\n")
        // A step held for the person's approval did not happen yet.
        let held = text.contains("\"needs_approval\"")
        let step = Step(
            id: list.count + 1, date: started, tool: tool, detail: Self.detail(tool: tool, args: args),
            ok: !result.isError && !held, summary: String(text.prefix(300)), url: webView?.url?.absoluteString,
            milliseconds: Int(Date().timeIntervalSince(started) * 1000))
        list.append(step)
        steps[task.id] = list
        task.steps = list.count
        if let url = webView?.url?.absoluteString { task.lastURL = url }
        append(step, taskID: task.id)
        if let webView, Self.changesPage.contains(tool) {
            Task { await self.captureFrame(step: step.id, taskID: task.id, webView: webView) }
        }
    }

    /// One readable line for the step. Typed secrets appear as their placeholders: the agent never had the value.
    static func detail(tool: String, args: [String: Any]) -> String {
        var args = args
        args.removeValue(forKey: "task")
        if let code = args["code"] as? String, code.count > 160 { args["code"] = String(code.prefix(160)) + "…" }
        if let actions = args["actions"] as? [[String: Any]] {
            return actions.map { step in
                let action = step["action"] as? String ?? "?"
                let target = (step["target"] as? String).map { " \($0)" } ?? ""
                let text = (step["text"] as? String).map { " \"\($0.prefix(60))\"" } ?? ""
                let url = (step["url"] as? String).map { " \($0)" } ?? ""
                let key = (step["key"] as? String).map { " \($0)" } ?? ""
                return action + target + text + url + key
            }.joined(separator: " · ")
        }
        return args.isEmpty ? "" : AgentJSON.compact(args)
    }

    private func append(_ step: Step, taskID: String) {
        let dir = Self.directory(for: taskID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("steps.jsonl")
        let line = Data((AgentJSON.compact(step.json) + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    private func captureFrame(step: Int, taskID: String, webView: WKWebView) async {
        // Let the page paint what the step did.
        try? await Task.sleep(for: .milliseconds(350))
        let config = WKSnapshotConfiguration()
        config.snapshotWidth = NSNumber(value: min(Double(webView.bounds.width), 720))
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let jpeg = AgentImages.jpeg(image, quality: 0.55) else { return }
        let url = Self.directory(for: taskID).appendingPathComponent(String(format: "%04d.jpg", step))
        guard (try? jpeg.write(to: url)) != nil else { return }
        if var list = steps[taskID], let index = list.firstIndex(where: { $0.id == step }) {
            list[index].frame = url
            steps[taskID] = list
        }
    }
}

enum AgentImages {
    static func jpeg(_ image: NSImage, quality: Double = 0.7) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
