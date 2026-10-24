// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPages.swift
//  Harbor
//
//  AgentKit's answers to an Agent space page (HarborWeb's AgentPageHost): a task's allowed sites,
//  JavaScript dialogs answered by the agent's policy and logged for it to read, file pickers
//  answered with the files `upload` staged, and the scripts agent pages get (WebMCP).
//

import Foundation
import WebKit
import HarborWeb

@MainActor
final class AgentDialogLog {
    struct Entry {
        let seq: Int
        let date: Date
        let kind: AgentDialogKind
        let message: String
        let answer: String
        let url: String
    }

    /// How the next dialogs on a page are answered.
    struct Policy {
        var accept = false
        var promptText: String?
    }

    private var entries: [UUID: [Entry]] = [:]
    private var policies: [UUID: Policy] = [:]
    private var seq = 0
    /// Files `upload` staged for the next file picker on a page.
    private var stagedFiles: [UUID: [URL]] = [:]

    func setPolicy(_ policy: Policy, for item: UUID) { policies[item] = policy }

    func entries(for item: UUID, since: Int) -> [Entry] { (entries[item] ?? []).filter { $0.seq > since } }

    var cursor: Int { seq }

    /// Forgets a closed tab's dialogs and policy.
    func forget(_ item: UUID) {
        entries.removeValue(forKey: item)
        policies.removeValue(forKey: item)
        stagedFiles.removeValue(forKey: item)
    }

    func answer(item: UUID, kind: AgentDialogKind, message: String, defaultText: String?, url: String) -> AgentDialogAnswer {
        let policy = policies[item] ?? Policy()
        // An alert has one button; confirm and prompt follow the policy, refusing by default.
        let answer = AgentDialogAnswer(accept: kind == .alert || policy.accept, text: policy.promptText ?? defaultText)
        seq += 1
        let shown = kind == .alert ? "ok" : !answer.accept ? "dismissed" : kind == .prompt ? "accepted: \(answer.text ?? "")" : "accepted"
        var list = entries[item] ?? []
        list.append(Entry(seq: seq, date: Date(), kind: kind, message: String(message.prefix(2000)), answer: shown, url: url))
        entries[item] = Array(list.suffix(100))
        return answer
    }

    func stage(_ files: [URL], for item: UUID) { stagedFiles[item] = files }

    func takeStaged(for item: UUID) -> [URL]? { stagedFiles.removeValue(forKey: item) }
}

@MainActor
final class AgentPages: AgentPageHost {
    weak var browser: BrowserManager?
    /// Sites the agent's own work tabs (a crawl, a recipe run, a watch) may open; a task's tab
    /// follows its task's list instead.
    private var scopes: [UUID: [String]] = [:]

    func setScope(_ origins: [String], for item: UUID) {
        scopes[item] = origins.filter { !$0.isEmpty }
    }

    func clearScope(for item: UUID) {
        scopes.removeValue(forKey: item)
    }

    init(browser: BrowserManager) {
        self.browser = browser
    }

    func agentPageScripts() -> [WKUserScript] {
        [AgentWebMCP.userScript]
    }

    func agentPage(_ session: PageSession, mayLoad url: URL) -> Bool {
        if let task = task(for: session.itemID) {
            guard !task.allowedOrigins.isEmpty, !task.allows(url) else { return true }
            AgentHub.log.notice("Task \(task.id, privacy: .public) kept off \(url.host ?? "", privacy: .public)")
            task.note = "Blocked \(url.host ?? url.absoluteString): outside the task's allowed sites"
            return false
        }
        guard let origins = lineage(of: session.itemID).lazy.compactMap({ self.scopes[$0] }).first, !origins.isEmpty else { return true }
        return AgentScope.allows(url, origins: origins)
    }

    func agentPage(_ session: PageSession, dialog kind: AgentDialogKind, message: String, defaultText: String?) -> AgentDialogAnswer {
        AgentHub.shared.dialogs.answer(item: session.itemID, kind: kind, message: message, defaultText: defaultText,
                                       url: session.url.absoluteString)
    }

    func agentPageOpenPanel(_ session: PageSession, allowsMultipleSelection: Bool) -> [URL]? {
        guard let files = AgentHub.shared.dialogs.takeStaged(for: session.itemID) else { return nil }
        return allowsMultipleSelection ? files : Array(files.prefix(1))
    }

    /// The task a page belongs to: its own, or that of the tab it was opened from (a popup or a
    /// link opened in a new tab is a trail child of its opener).
    func task(for itemID: UUID) -> AgentTask? {
        lineage(of: itemID).lazy.compactMap { AgentHub.shared.tasks.task(forItem: $0) }.first
    }

    /// The task that owns the tab, ended or not: a task's tab stays the task's.
    func owner(of itemID: UUID) -> AgentTask? {
        lineage(of: itemID).lazy.compactMap { id in AgentHub.shared.tasks.all.last { $0.itemID == id } }.first
    }

    /// The tab and the tabs it was opened from, nearest first.
    private func lineage(of itemID: UUID) -> [UUID] {
        guard let tabs = browser?.tabs else { return [itemID] }
        var chain = [itemID]
        while chain.count < 8, case .folder(let parent)? = tabs.item(chain[chain.count - 1])?.parent {
            chain.append(parent)
        }
        return chain
    }
}
