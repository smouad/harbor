// Licensed under GPL-3.0. See LICENSE.
//
//  AgentRecorder.swift
//  Harbor
//
//  Demonstrate mode: the person does a task once in a tab and Harbor keeps each click, typed
//  field, choice and key as a recipe step, with several selectors per element so a later run
//  survives page changes. The runtime reports steps as they happen through a message handler in
//  its own content world (a page cannot post to it), so a navigation loses nothing. Typed text
//  becomes the recipe's inputs; passwords and card fields are never kept.
//

import Foundation
import Observation
import WebKit

@MainActor
@Observable
final class AgentRecorder {
    private(set) var isRecording = false
    private(set) var steps: [[String: Any]] = []
    private(set) var startURL: URL?
    /// What is being recorded, for the indicator: the person's tab or an agent's.
    private(set) var subject = ""

    @ObservationIgnored private weak var webView: WKWebView?
    @ObservationIgnored private var handler: Handler?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var lastStepAt = Date.distantPast
    @ObservationIgnored private var hosts: [String] = []

    static let handlerName = "harborAgentRecord"

    /// A step caused by the person's own click or key within this long is not a new navigation.
    private static let causedNavigationWindow: TimeInterval = 2

    func start(in webView: WKWebView, subject: String) async throws {
        if isRecording { _ = stop() }
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else {
            throw AgentError.invalid("Open a web page in that tab first")
        }
        self.webView = webView
        self.subject = subject
        steps = [["action": "navigate", "url": url.absoluteString, "label": "Open \(url.host ?? "")"]]
        startURL = url
        hosts = [url.host ?? ""]
        lastStepAt = Date()
        let handler = Handler { [weak self] body in self?.append(body) }
        self.handler = handler
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: AgentRuntime.world)
        controller.add(handler, contentWorld: AgentRuntime.world, name: Self.handlerName)
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.urlChanged(view.url) }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                guard !view.isLoading else { return }
                Task { @MainActor in await self?.arm() }
            }
        ]
        isRecording = true
        await arm()
    }

    /// Ends the recording and hands back its steps.
    @discardableResult
    func stop() -> [[String: Any]] {
        guard isRecording else { return steps }
        isRecording = false
        observations.forEach { $0.invalidate() }
        observations = []
        if let webView {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: AgentRuntime.world)
            Task { _ = try? await AgentRuntime.call("recordStop", in: webView) }
        }
        handler = nil
        webView = nil
        return steps
    }

    /// Each new document starts without the recorder, so it is switched on again after a load.
    private func arm() async {
        guard isRecording, let webView else { return }
        _ = try? await AgentRuntime.call("recordStart", in: webView)
    }

    private func append(_ body: Any) {
        guard isRecording, var step = body as? [String: Any], let action = step["action"] as? String else { return }
        var clean: [String: Any] = ["action": action]
        let candidates = step["candidates"] as? [String] ?? []
        if let first = candidates.first {
            clean["target"] = first
            if candidates.count > 1 { clean["targets"] = candidates }
        }
        if let label = step["label"] as? String { clean["label"] = label }
        for key in ["text", "value", "key"] { if let value = step[key] { clean[key] = value } }
        if step["sensitive"] as? Bool == true {
            clean["text"] = ""
            clean["sensitive"] = true
        }
        // Typing into the same field again replaces the earlier entry.
        if action == "fill", let last = steps.last, last["action"] as? String == "fill", last["target"] as? String == clean["target"] as? String {
            steps.removeLast()
        }
        step = clean
        steps.append(step)
        lastStepAt = Date()
    }

    private func urlChanged(_ url: URL?) {
        guard isRecording, let url, url.scheme?.hasPrefix("http") == true else { return }
        if let host = url.host, !hosts.contains(host) { hosts.append(host) }
        // A page change right after a click or key is that step's doing; replaying the step
        // repeats it. Anything else (typed address, bookmark) becomes a navigate step.
        guard Date().timeIntervalSince(lastStepAt) > Self.causedNavigationWindow else { return }
        if steps.last?["action"] as? String == "navigate" { steps.removeLast() }
        steps.append(["action": "navigate", "url": url.absoluteString, "label": "Open \(url.host ?? "")"])
        lastStepAt = Date()
    }

    // MARK: - Recipe

    /// The recording as a recipe: each typed field becomes an input named after its label, with
    /// what was typed as the default.
    func recipe(name: String, description: String, expose: Bool) throws -> AgentRecipe {
        guard AgentRecipe.isValidName(name) else { throw AgentError.invalid("A recipe name is letters, digits, dash or underscore") }
        guard steps.count > 1 else { throw AgentError.invalid("Nothing was recorded after opening the page") }
        var vars: [String: Any] = [:]
        var built: [[String: Any]] = []
        for var step in steps {
            if step["action"] as? String == "fill" {
                let base = Self.varName(from: step["label"] as? String ?? "field")
                var key = base
                var n = 2
                while vars[key] != nil { key = "\(base)_\(n)"; n += 1 }
                vars[key] = step["text"] ?? ""
                step["text"] = "${vars.\(key)}"
            }
            built.append(step)
        }
        var about = description
        if built.contains(where: { $0["sensitive"] as? Bool == true }) {
            about += (about.isEmpty ? "" : " ") + "Password fields were left empty: pass them as {{secret:name}}."
        }
        return AgentRecipe(name: name, description: about, sites: hosts.filter { !$0.isEmpty }, vars: vars, expose: expose, steps: built)
    }

    /// `textbox "Search Wikipedia"` → `search_wikipedia`.
    static func varName(from label: String) -> String {
        let name = label.split(separator: "\"").dropFirst().first.map(String.init) ?? label
        let words = name.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(4)
        let joined = words.joined(separator: "_")
        return joined.isEmpty ? "field" : String(joined.prefix(30))
    }

    private final class Handler: NSObject, WKScriptMessageHandler {
        let onStep: (Any) -> Void

        init(onStep: @escaping (Any) -> Void) {
            self.onStep = onStep
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            onStep(message.body)
        }
    }
}
