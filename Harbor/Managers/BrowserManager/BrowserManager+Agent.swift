// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Agent.swift
//  Harbor
//
//  Keeps the DevMCP agent's page rendering while the person looks at another space. WebKit
//  treats a page outside any window as hidden (no rendering, 1 Hz timers), so the agent's page
//  sits in a browser window, in a view placed outside the window's content area: nothing draws,
//  no tracking area or click reaches it, and WebKit still counts it visible. Each task has its own
//  page, so several can be hosted at once; one that no tool call used for 30 s leaves the window,
//  so an idle agent page costs what a background tab does.
//

import AppKit
import WebKit
import HarborWeb

/// When each hosted agent page was last used by a tool call.
@MainActor private var agentLastUse: [UUID: Date] = [:]
/// Pages taken out of the window for being idle; the next tool call on one hosts it again.
@MainActor private var agentParked: Set<UUID> = []
@MainActor private var agentIdle: Task<Void, Never>?

extension BrowserManager {
    private static let agentIdleDelay: TimeInterval = 30
    /// Pages rendering at once for tasks; past this the least recently used one is parked.
    private static let agentHostedLimit = 6

    func installAgentPageHost() {
        let pages = AgentPages(browser: self)
        AgentHub.shared.pages = pages
        tabs.agentHost = pages
        AgentHub.shared.configure(browser: self)
        // A parked page comes back only through a tool call (agentWebView(item:)): re-hosting it
        // here while calls ran made the page the newest, parked the next oldest, and so on.
        tabs.onAgentPage = { [weak self] session in
            guard let self, !agentParked.contains(session.itemID) else { return }
            self.useAgentPage(session)
        }
    }

    /// The Agent space's current page, loaded, in a window and counted as used. Nil without an
    /// Agent space tab; throws when the tab's page cannot be made.
    func agentWebView() throws -> WKWebView? {
        guard let id = tabs.agentItem else { return nil }
        return try agentWebView(item: id)
    }

    /// An Agent space tab's page (a task's), loaded, hosted and counted as used.
    func agentWebView(item id: UUID) throws -> WKWebView {
        guard tabs.isInAgentSpace(id), let session = tabs.ensureSession(for: id) else { throw AgentPageError.noPage }
        session.loadWebViewIfNeeded()
        guard let view = session.webView else { throw AgentPageError.noPage }
        compositorManager.markTabAccessed(id)
        useAgentPage(session)
        return view
    }

    /// A new tab in the Agent space, in the background: the agent's current tab stays its own,
    /// and no window changes what it shows. `scope` limits the sites it may open (none: any).
    /// Nil when there is no space to borrow logins from.
    func openAgentTab(url: URL?, title: String?, scope: [String] = []) -> UUID? {
        guard let window = (windowRegistry?.activeWindow).flatMap({ $0.isIncognito ? nil : $0 }) ?? tabs.regularWindows.first,
              let agent = tabs.ensureAgentSpace(loginsFrom: window),
              let id = tabs.open(url: url ?? URL(string: "about:blank")!, in: window, placement: .background, parent: .tabs(spaceID: agent))
        else { return nil }
        if let title { tabs.rename(id, title) }
        AgentHub.shared.pages?.setScope(scope, for: id)
        return id
    }

    /// Ends an Agent space tab the agent opened for its own work (a job, a watch).
    func closeAgentTab(_ id: UUID) {
        guard tabs.isInAgentSpace(id) else { return }
        agentLastUse.removeValue(forKey: id)
        agentParked.remove(id)
        AgentHub.shared.pages?.clearScope(for: id)
        AgentHub.shared.dialogs.forget(id)
        tabs.remove(id)
    }

    private func useAgentPage(_ session: PageSession) {
        agentParked.remove(session.itemID)
        agentLastUse[session.itemID] = Date()
        hostAgentPage(session)
        scheduleAgentIdle()
    }

    /// Puts an agent page in the active window's hidden host when no open window holds it; a
    /// window that shows the Agent space takes it from there itself.
    func hostAgentPage(_ session: PageSession) {
        guard tabs.isInAgentSpace(session.itemID), let view = session.webView,
              let window = ((windowRegistry?.activeWindow).flatMap { $0.isIncognito ? nil : $0 } ?? tabs.regularWindows.first)?.window,
              let content = window.contentView else { return }
        // Already in a window that is still open; a closed one no longer renders it.
        if let current = view.window, current === window || current.isVisible || current.isMiniaturized { return }
        let host = content.subviews.first { $0 is AgentPageHostView } ?? {
            // A fixed desktop size, not the window's: the agent sees the same layout whatever
            // window happens to host it (a narrow one gave sites their phone layout).
            let host = AgentPageHostView(frame: NSRect(origin: NSPoint(x: -AgentPageHostView.offset, y: 0), size: AgentPageHostView.size))
            host.alphaValue = 0
            // Clipped and outside the content area, so its visible rect, and every tracking area
            // in it, is empty.
            host.clipsToBounds = true
            content.addSubview(host, positioned: .below, relativeTo: nil)
            return host
        }()
        // Into the window first, then sized: WebKit resizes its drawing view only for the first
        // frame change made off-window, and the page then draws at that size inside the Agent
        // space's narrower pane (see CLAUDE.md, "Never resize a WKWebView before it is in a window").
        host.addSubview(view)
        view.frame = host.bounds
        view.autoresizingMask = [.width, .height]
        parkOverflow(in: host)
    }

    /// Keeps at most `agentHostedLimit` pages rendering, parking the least recently used.
    private func parkOverflow(in host: NSView) {
        let hosted = host.subviews.compactMap { $0 as? FocusableWKWebView }
        guard hosted.count > Self.agentHostedLimit else { return }
        let byAge = hosted.sorted { lastUse($0) < lastUse($1) }
        for view in byAge.prefix(hosted.count - Self.agentHostedLimit) { park(view) }
    }

    private func lastUse(_ view: FocusableWKWebView) -> Date {
        view.owningSession.flatMap { agentLastUse[$0.itemID] } ?? .distantPast
    }

    private func park(_ view: FocusableWKWebView) {
        if let id = view.owningSession?.itemID {
            agentParked.insert(id)
            agentLastUse.removeValue(forKey: id)
        }
        view.removeFromSuperview()
    }

    /// Takes each hosted page out of its host once no call has used it for `agentIdleDelay`.
    private func scheduleAgentIdle() {
        agentIdle?.cancel()
        agentIdle = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, let oldest = agentLastUse.values.min() else { return }
                let wait = oldest.addingTimeInterval(Self.agentIdleDelay).timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    continue
                }
                if self.tabs.agentCallsInFlight > 0 {
                    try? await Task.sleep(for: .seconds(Self.agentIdleDelay))
                    continue
                }
                let cutoff = Date().addingTimeInterval(-Self.agentIdleDelay)
                for (id, used) in agentLastUse where used <= cutoff {
                    if let view = self.tabs.session(for: id)?.webView as? FocusableWKWebView,
                       view.superview is AgentPageHostView {
                        self.park(view)
                    } else {
                        agentLastUse.removeValue(forKey: id)
                    }
                }
            }
        }
    }
}

enum AgentPageError: LocalizedError {
    case noPage
    var errorDescription: String? { "The Agent space's tab has no page" }
}

/// Holds the agent's page out of sight: transparent, outside the content area, never the target
/// of a click.
final class AgentPageHostView: NSView {
    /// How far left of the content area the host sits; wider than any window.
    static let offset: CGFloat = 20_000
    /// The viewport agent pages get while hosted here.
    static let size = NSSize(width: 1440, height: 900)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityChildren() -> [Any]? { [] }
}
