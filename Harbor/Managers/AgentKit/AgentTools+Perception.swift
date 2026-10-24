// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Perception.swift
//  Harbor
//
//  extract (a question about the page, answered on the device), ocr (text read off the pixels),
//  and WebMCP: site_tools and site_tool_call for tools the page itself offers agents.
//

import AppKit
import Foundation
import WebKit

extension AgentToolbox {
    static let perceptionTools: [AgentTool] = [extract, ocr]
    static let siteTools: [AgentTool] = [siteToolList, siteToolCall]

    private static let extract = AgentTool(
        "extract",
        "Ask Apple Intelligence on this Mac a question about the page (\"list the prices\", \"the order number as JSON\"). The page never leaves the Mac and costs you no tokens. It reads about 7,000 characters of the page's Markdown; pass selector to aim it.",
        properties: ["instruction": ["type": "string"], "selector": ["type": "string"]],
        required: ["instruction"]
    ) { call in
        let webView = try call.page()
        var options: [String: Any] = ["maxLength": AgentOnDevice.extractBudget + 1000]
        if let selector = call.args.string("selector") { options["selector"] = selector }
        let page = try await AgentRuntime.object("markdown", options, in: webView)
        let instruction = try call.args.required("instruction")
        let answer = try await AgentDeadline.throwing(call.remaining - 1) {
            try await AgentOnDevice.extract(instruction: instruction, text: page["markdown"] as? String ?? "")
        }
        return .untrusted(answer, origin: webView.url?.host)
    }

    private static let ocr = AgentTool(
        "ocr",
        "Text read off the page's pixels with Vision, for what the DOM does not hold (canvas, images, video frames, PDFs). Lines with confidence and boxes in viewport CSS pixels. selector limits it to one element.",
        properties: ["selector": ["type": "string"]]
    ) { call in
        let webView = try call.page()
        // Bring the element into view before the capture, so its box and the picture agree.
        var region: CGRect?
        if let selector = call.args.string("selector") {
            let element = try await AgentRuntime.object("point", ["target": selector], in: webView)["element"] as? [String: Any] ?? [:]
            let n = { (key: String) in (element[key] as? NSNumber)?.doubleValue ?? 0 }
            region = CGRect(x: n("x"), y: n("y"), width: n("w"), height: n("h"))
        }
        let image = try await AgentPerception.visible(webView, maxWidth: 2400)
        let viewport = try await AgentRuntime.object("point", ["x": 0, "y": 0], in: webView)["viewport"] as? [String: Any]
        let cssWidth = (viewport?["w"] as? NSNumber)?.doubleValue ?? Double(webView.bounds.width)
        let toCSS = cssWidth / Double(image.size.width)
        let lines = try await AgentPerception.recognizeText(in: image).compactMap { line -> [String: Any]? in
            let box = CGRect(x: line.box.minX * toCSS, y: line.box.minY * toCSS, width: line.box.width * toCSS, height: line.box.height * toCSS)
            if let region, !region.intersects(box) { return nil }
            return ["text": line.text, "confidence": (Double(line.confidence) * 100).rounded() / 100,
                    "x": Int(box.minX), "y": Int(box.minY), "w": Int(box.width), "h": Int(box.height)]
        }
        return .untrusted(["lines": lines], origin: webView.url?.host)
    }

    private static let siteToolList = AgentTool(
        "site_tools",
        "Tools the page offers agents through WebMCP (document.modelContext.registerTool): name, description, input schema. When a site has one for what you need, calling it beats clicking through its UI.",
        properties: [:]
    ) { call in
        let webView = try call.page()
        return .untrusted(["url": webView.url?.absoluteString ?? "", "tools": try await AgentWebMCP.tools(in: webView)], origin: webView.url?.host)
    }

    private static let siteToolCall = AgentTool(
        "site_tool_call",
        "Call a tool the page registered with WebMCP, with arguments matching its input schema. In a task, a tool whose name sounds like it buys, sends or deletes asks the person first.",
        properties: ["name": ["type": "string"], "arguments": ["type": "object"]],
        required: ["name"]
    ) { call in
        let webView = try call.page()
        let name = try call.args.required("name")
        if let task = call.task, task.confirm != .never {
            var facts = AgentActionFacts(action: "click")
            facts.role = "site tool"
            facts.name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            facts.host = webView.url?.host ?? ""
            if let pending = await AgentHub.shared.approvals.gate(task: task, facts: facts) {
                return .json(["ok": false, "needs_approval": pending.id, "reason": pending.reason])
            }
        }
        let arguments = call.args.object("arguments") ?? [:]
        // The page's own promise: it may never settle.
        let result = try await AgentDeadline.throwing(call.remaining - 1) {
            try await AgentWebMCP.call(name, arguments: arguments, in: webView)
        }
        return .untrusted(result ?? NSNull(), origin: webView.url?.host)
    }
}
