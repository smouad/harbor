// Licensed under GPL-3.0. See LICENSE.
//
//  AgentWebMCP.swift
//  Harbor
//
//  WebMCP (W3C Web Machine Learning CG draft): a page registers tools on `document.modelContext`
//  (formerly `navigator.modelContext`) and an agent calls them instead of clicking through the
//  UI. Agent pages get the API at document start, in the page's own world since the page calls
//  it; Harbor reads the registry back through `site_tools` and `site_tool_call`. Pages a person
//  browses do not get it, so the API is not a new fingerprint for every site.
//

import Foundation
import WebKit

@MainActor
enum AgentWebMCP {
    static let userScript = WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page)

    /// The tools the page registered: name, description, input schema.
    static func tools(in webView: WKWebView) async throws -> [[String: Any]] {
        let result = try await webView.callAsyncJavaScript(
            "return globalThis.__harborWebMCP ? globalThis.__harborWebMCP.list() : null", contentWorld: .page)
        guard let list = result as? [[String: Any]] else {
            throw AgentError.invalid("This page has no WebMCP: it loaded before Browser Control or is not an agent page. Reload it.")
        }
        return list
    }

    static func call(_ name: String, arguments: [String: Any], in webView: WKWebView) async throws -> Any? {
        let result = try await webView.callAsyncJavaScript(
            "return await globalThis.__harborWebMCP.call(name, input)",
            arguments: ["name": name, "input": arguments], contentWorld: .page)
        return result is NSNull ? nil : result
    }

    private static let source = #"""
    // Harbor Agent WebMCP
    (() => {
        if (window.__harborWebMCP) return;
        const tools = new Map();
        const events = new EventTarget();
        let ontoolchange = null;

        const changed = () => {
            const event = new Event("toolchange");
            events.dispatchEvent(event);
            if (typeof ontoolchange === "function") { try { ontoolchange(event); } catch (e) { console.error(e); } }
        };

        function registerTool(tool) {
            if (!tool || typeof tool.name !== "string" || !tool.name) throw new TypeError("registerTool: a tool needs a name");
            if (typeof tool.execute !== "function") throw new TypeError("registerTool: a tool needs an execute function");
            if (tools.has(tool.name)) throw new DOMException(`A tool named ${tool.name} is already registered`, "InvalidStateError");
            tools.set(tool.name, tool);
            changed();
            return { unregister: () => unregisterTool(tool.name) };
        }

        function unregisterTool(name) {
            if (tools.delete(name)) changed();
        }

        const describe = tool => ({
            name: tool.name,
            description: String(tool.description || ""),
            inputSchema: tool.inputSchema || { type: "object", properties: {} },
            annotations: tool.annotations || {}
        });

        async function executeTool(name, input) {
            const tool = tools.get(name);
            if (!tool) throw new DOMException(`No tool named ${name}`, "NotFoundError");
            // The agent stands in for the person, so a request for their attention runs at once.
            const client = { requestUserInteraction: async callback => await callback() };
            return await tool.execute(input || {}, client);
        }

        const modelContext = Object.freeze({
            registerTool,
            unregisterTool,
            getTools: () => [...tools.values()].map(describe),
            executeTool,
            // Removed from the draft in March 2026; sites written against it keep working.
            provideContext: ({ tools: list = [] } = {}) => { tools.clear(); list.forEach(t => tools.set(t.name, t)); changed(); },
            clearContext: () => { tools.clear(); changed(); },
            addEventListener: (...a) => events.addEventListener(...a),
            removeEventListener: (...a) => events.removeEventListener(...a),
            get ontoolchange() { return ontoolchange; },
            set ontoolchange(fn) { ontoolchange = fn; }
        });

        for (const proto of [Navigator.prototype, Document.prototype]) {
            Object.defineProperty(proto, "modelContext", { get: () => modelContext, configurable: true, enumerable: true });
        }

        Object.defineProperty(window, "__harborWebMCP", {
            value: Object.freeze({
                list: () => [...tools.values()].map(describe),
                call: async (name, input) => {
                    const result = await executeTool(name, input);
                    try { return JSON.parse(JSON.stringify(result ?? null)); } catch { return String(result); }
                }
            })
        });
    })();
    """#
}
