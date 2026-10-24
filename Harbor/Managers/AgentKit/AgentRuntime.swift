// Licensed under GPL-3.0. See LICENSE.
//
//  AgentRuntime.swift
//  Harbor
//
//  Calls into agent-runtime.js, the agent's page runtime. It lives in its own content world, so
//  the page can neither see it nor patch the functions it uses, and it is injected on first use
//  in each document rather than as a user script: one per call costs nothing, and pages that
//  loaded before Browser Control turned on work too.
//

import Foundation
import WebKit

@MainActor
enum AgentRuntime {
    static let world = WKContentWorld.world(name: "HarborAgent")

    private static let source: String = {
        guard let url = Bundle.main.url(forResource: "agent-runtime", withExtension: "js"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("agent-runtime.js is missing from the app bundle")
        }
        return text
    }()

    /// Runs `op` in the page's runtime, installing it first when this document has none.
    /// Values come back as Foundation types (dictionaries, arrays, numbers, strings).
    static func call(_ op: String, _ args: [String: Any] = [:], in webView: WKWebView) async throws -> Any? {
        let installed = try await webView.callAsyncJavaScript(
            "return typeof globalThis.__harborAgent === 'object'", contentWorld: world) as? Bool ?? false
        if !installed {
            _ = try await webView.callAsyncJavaScript(source, contentWorld: world)
        }
        let result = try await webView.callAsyncJavaScript(
            "return await globalThis.__harborAgent.call(op, args)",
            arguments: ["op": op, "args": args], contentWorld: world)
        return result is NSNull ? nil : result
    }

    static func object(_ op: String, _ args: [String: Any] = [:], in webView: WKWebView) async throws -> [String: Any] {
        try await call(op, args, in: webView) as? [String: Any] ?? [:]
    }

    /// Whether this document holds a secret: a vault value typed into it, or any password field
    /// with something in it (a password manager extension fills those without Harbor knowing the
    /// value, so it cannot be scrubbed). Scripts can read any field, so they wait until the page
    /// moves on, or until the person approves them in a task.
    static func secretTyped(in webView: WKWebView) async -> Bool {
        // Through open shadow roots and same-origin frames. When the check itself fails, assume a
        // secret is there: a script must not run on a guess.
        let typed = try? await webView.callAsyncJavaScript("""
            const filled = root => [...root.querySelectorAll("input[type=password]")].some(i => i.value)
                || [...root.querySelectorAll("*")].some(el => el.shadowRoot && filled(el.shadowRoot))
                || [...root.querySelectorAll("iframe, frame")].some(f => { try { return !!f.contentDocument && filled(f.contentDocument); } catch { return false; } });
            if (filled(document)) return true;
            return typeof globalThis.__harborAgent === 'object' && await globalThis.__harborAgent.call('secretTyped', {});
            """, contentWorld: world)
        return typed as? Bool ?? true
    }

    static let secretScriptRefusal = "A password is in a field on this page (typed from the vault or filled by a password manager), so scripts wait until the page changes. In a task, the person can approve them."
}

/// The runtime's errors arrive as WKError with the JavaScript message buried in userInfo.
extension Error {
    var agentMessage: String {
        let ns = self as NSError
        if let message = ns.userInfo["WKJavaScriptExceptionMessage"] as? String {
            return message.replacingOccurrences(of: "Error: ", with: "")
        }
        return localizedDescription
    }
}
