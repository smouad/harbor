// Licensed under GPL-3.0. See LICENSE.
//
//  PasswordAutofillManager.swift
//  Harbor
//
//  Shows the saved logins under a login field and fills the one the person picks. The page only
//  says "the cursor is in a login field"; this looks up what belongs to the page's own site
//  (from WebKit's record of its origin, never from the page's message), keeps the passwords out of
//  the page until one is picked, and refuses private data to anything but a trusted origin.
//

import AppKit
import SwiftUI
import WebKit
import os
import HarborWeb

@MainActor
final class PasswordAutofillManager {
    private weak var browserManager: BrowserManager?
    private static let log = Logger(subsystem: "com.mouad.harbor", category: "Autofill")

    private struct Prompt {
        var all: [SavedLogin]
        var logins: [SavedLogin]
        var keyboardIndex: Int?
        var field: AutofillField
        weak var session: PageSession?
        weak var webView: WKWebView?
        let view: AutofillHostingView
    }

    private var prompt: Prompt?
    /// A reply for an older focus must not open over a newer one.
    private var generation = 0

    init(browserManager: BrowserManager) {
        self.browserManager = browserManager
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
    }

    // MARK: - From the page

    func fieldFocused(_ field: AutofillField, in session: PageSession) {
        Self.log.notice("field focused: \(field.kind.rawValue, privacy: .public) on \(field.scheme, privacy: .public)://\(field.host, privacy: .public)")
        guard LoginMatching.isTrusted(scheme: field.scheme, host: field.host),
              let webView = field.webView, webView.window != nil else {
            Self.log.notice("not offered: untrusted origin or no window")
            return dismiss()
        }

        // Typing narrows the list that is already up; no need to ask the store again.
        if var current = prompt, current.webView === webView, field.kind == current.field.kind {
            current.field = field
            current.logins = Self.narrowed(current.all, by: field.typed)
            current.keyboardIndex = nil
            prompt = current
            return current.logins.isEmpty ? dismiss() : refresh()
        }

        generation += 1
        let token = generation
        // The space only orders the list: every login for the site is offered in every window.
        let space = session.isPrivate ? nil : browserManager?.tabs.spaceID(of: session.itemID)
        Task {
            let found = await PasswordStore.shared.logins(forHost: field.host, space: space)
            Self.log.notice("\(found.count) saved logins for \(field.host, privacy: .public)")
            guard token == generation else { return }
            let shown = Self.narrowed(found, by: field.typed)
            guard !shown.isEmpty, let webView = field.webView, webView.window != nil else {
                Self.log.notice("nothing to show (\(shown.count) after narrowing)")
                return dismiss()
            }
            present(all: found, shown: shown, field: field, session: session, webView: webView)
            Self.log.notice("dropdown shown with \(shown.count) logins at \(String(describing: self.prompt?.view.frame), privacy: .public)")
        }
    }

    func key(_ key: AutofillKey, in session: PageSession) {
        guard var current = prompt, current.session === session else { return }
        switch key {
        case .down:
            current.keyboardIndex = min((current.keyboardIndex ?? -1) + 1, current.logins.count - 1)
        case .up:
            current.keyboardIndex = current.keyboardIndex.map { $0 > 0 ? $0 - 1 : nil } ?? nil
        case .enter:
            if let index = current.keyboardIndex, current.logins.indices.contains(index) { return pick(current.logins[index]) }
            return
        case .escape:
            return dismiss()
        }
        prompt = current
        refresh()
    }

    func dismiss() {
        generation += 1
        guard let current = prompt else { return }
        prompt = nil
        current.view.removeFromSuperview()
        if let webView = current.webView { AutofillBridge.setState(open: false, highlighted: false, in: webView) }
    }

    func dismiss(session: PageSession) {
        if prompt?.session === session { dismiss() }
    }

    // MARK: - Showing

    private func present(all: [SavedLogin], shown: [SavedLogin], field: AutofillField, session: PageSession, webView: WKWebView) {
        dismiss()
        guard let content = webView.window?.contentView else { return }
        let view = AutofillHostingView(rootView: dropdown(logins: shown, keyboardIndex: nil, width: Self.width(for: field, webView: webView)))
        view.safeAreaRegions = []
        content.addSubview(view, positioned: .above, relativeTo: nil)
        prompt = Prompt(all: all, logins: shown, keyboardIndex: nil, field: field, session: session, webView: webView, view: view)
        refresh()
    }

    /// Rebuilds the list and puts it under the field.
    private func refresh() {
        guard let current = prompt, let webView = current.webView, let content = webView.window?.contentView else { return }
        let width = Self.width(for: current.field, webView: webView)
        current.view.rootView = dropdown(logins: current.logins, keyboardIndex: current.keyboardIndex, width: width)
        let size = current.view.fittingSize
        current.view.frame = Self.frame(of: current.field, in: webView, content: content, size: size)
        AutofillBridge.setState(open: true, highlighted: current.keyboardIndex != nil, in: webView)
    }

    private func dropdown(logins: [SavedLogin], keyboardIndex: Int?, width: CGFloat) -> AutofillDropdownView {
        AutofillDropdownView(
            logins: logins, keyboardIndex: keyboardIndex, width: width,
            onPick: { [weak self] login in self?.pick(login) },
            onManage: { [weak self] in
                self?.dismiss()
                self?.browserManager?.openSettings(tab: .passwords)
            })
    }

    // MARK: - Filling

    private func pick(_ login: SavedLogin) {
        guard let webView = prompt?.webView else { return }
        dismiss()
        Task {
            // The password leaves the keychain here and goes straight into the page.
            guard let password = await PasswordStore.shared.password(for: login) else { return NSSound.beep() }
            await AutofillBridge.fill(username: login.username, password: password, in: webView)
            // Choosing in the list must not leave the page without focus.
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Geometry

    private static let minimumWidth: CGFloat = 280

    private static func width(for field: AutofillField, webView: WKWebView) -> CGFloat {
        max(field.rect.width * webView.pageZoom, minimumWidth)
    }

    /// The field's box in the page's units is in the web view's own space; this puts the list
    /// just under it (or over it when there is no room), inside the window.
    private static func frame(of field: AutofillField, in webView: WKWebView, content: NSView, size: CGSize) -> NSRect {
        let zoom = webView.pageZoom
        let box = NSRect(x: field.rect.minX * zoom, y: field.rect.minY * zoom + webView.obscuredContentInsets.top,
                         width: field.rect.width * zoom, height: field.rect.height * zoom)
        let anchor = content.convert(box, from: webView)
        let gap: CGFloat = 4, edge: CGFloat = 8
        let x = min(max(anchor.minX, edge), max(edge, content.bounds.width - size.width - edge))
        let y: CGFloat
        if content.isFlipped {
            let below = anchor.maxY + gap
            y = below + size.height <= content.bounds.height - edge ? below : max(edge, anchor.minY - gap - size.height)
        } else {
            let below = anchor.minY - gap - size.height
            y = below >= edge ? below : min(content.bounds.height - size.height - edge, anchor.maxY + gap)
        }
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private static func narrowed(_ logins: [SavedLogin], by typed: String?) -> [SavedLogin] {
        guard let typed = typed?.trimmingCharacters(in: .whitespaces).lowercased(), !typed.isEmpty else { return logins }
        return logins.filter { $0.username.lowercased().hasPrefix(typed) }
    }
}

/// Takes clicks without taking focus from the page: the field must stay focused, or a page that
/// validates on blur complains before the login is even filled in.
private final class AutofillHostingView: NSHostingView<AutofillDropdownView> {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
