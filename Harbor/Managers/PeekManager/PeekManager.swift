// Licensed under GPL-3.0. See LICENSE.
//
//  PeekManager.swift
//  Harbor
//
//  Created by Jonathan Caudill on 24/09/2025.
//

import Foundation
import HarborWeb

/// Peek: a link shown in a card over one window, as a detached page that runs like a tab and
/// becomes one when moved to a tab or split.
@MainActor
@Observable
final class PeekManager {
    /// The page Peek shows, outside the tab tree until it moves to a tab.
    private(set) var page: PageSession?
    /// The window Peek opened in; the others show nothing.
    private(set) var windowId: UUID?
    /// How far the card has been pinched: positive grows it, negative shrinks it. The card follows it
    /// while the fingers are down; lifting them past `pinchThreshold` opens the page as a tab (out)
    /// or closes Peek (in).
    private(set) var pinch: Double = 0
    private static let pinchOpenThreshold = 0.25
    private static let pinchCloseThreshold = -0.2

    /// The tab Peek was opened from; moving the page to a tab nests it there.
    @ObservationIgnored private var openerID: UUID?

    @ObservationIgnored weak var browserManager: BrowserManager?

    func attach(browserManager: BrowserManager) {
        self.browserManager = browserManager
    }

    func presentExternalURL(_ url: URL, from source: PageSession?) {
        guard let browserManager else { return }

        // The same link again closes Peek.
        if page?.url == url {
            dismissPeek()
            return
        }

        // A private page never falls back to the default persistent store.
        guard let source, let profile = source.profile else { return }
        let window = browserManager.tabs.window(for: source)

        dismissPeek()
        let page = browserManager.tabs.openDetached(url: url, profile: profile, in: window)
        page.onClose = { [weak self] in self?.dismissPeek() }
        page.onMagnify = { [weak self] change, ended in self?.pinched(by: change, ended: ended) }
        self.page = page
        windowId = window?.id
        openerID = source.itemID
    }

    private func pinched(by change: Double, ended: Bool) {
        pinch += change
        guard ended else { return }
        let total = pinch
        pinch = 0
        if total >= Self.pinchOpenThreshold {
            moveToNewTab()
        } else if total <= Self.pinchCloseThreshold {
            dismissPeek()
        }
    }

    func dismissPeek() {
        guard let page else { return }
        pinch = 0
        page.onMagnify = nil
        self.page = nil
        windowId = nil
        browserManager?.tabs.endDetached(page)
    }

    func moveToSplitView() {
        guard let page, let browserManager, let window = page.detachedWindow else { return }
        let previous = window.selectedItemID
        pinch = 0
        page.onMagnify = nil
        self.page = nil
        windowId = nil
        guard let itemID = browserManager.tabs.adopt(page, in: window, from: openerID) else { return }
        // The adopted page is selected; pair it with the page the window showed before.
        if let previous, previous != itemID {
            browserManager.tabs.select(previous, in: window)
            browserManager.splitManager.enterSplit(with: itemID, placeOn: .right, in: window)
        }
    }

    func moveToNewTab() {
        guard let page, let browserManager, let window = page.detachedWindow else { return }
        pinch = 0
        page.onMagnify = nil
        self.page = nil
        windowId = nil
        browserManager.tabs.adopt(page, in: window, from: openerID)
    }

    var canEnterSplitView: Bool {
        guard let browserManager, let windowId else { return false }
        return !browserManager.splitManager.isSplit(for: windowId)
    }
}
