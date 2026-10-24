// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Import.swift
//  Harbor
//

import Foundation
import HarborTabsCore
import HarborWeb
import SwiftUI

extension BrowserManager {
    /// Imports Arc's spaces in Arc's order, each with its own pinned tabs and folders, open tabs,
    /// favorites (from the space's Arc profile) and color. A space Harbor made on first launch
    /// and nobody has used yet is replaced instead of left beside them.
    func importArcData() async {
        let result = await importManager.importArcSidebarData()
        guard let window = importWindow, let original = importSpaceID(window), !result.spaces.isEmpty else { return }
        let replaceOriginal = isUntouchedStarterSpace(original)

        var lastSpace = tabs.orderedSpaces.last?.id
        var firstImported: UUID?
        for space in result.spaces {
            guard let spaceID = tabs.createSpace(
                name: space.title, icon: space.emoji ?? "person.fill",
                accentHex: space.accentHex ?? "#7C7C7C", after: lastSpace
            ) else { continue }
            lastSpace = spaceID
            firstImported = firstImported ?? spaceID
            importTabs(space.unpinned.map(\.url), into: .tabs(spaceID: spaceID), window: window)
            importItems(space.pinned, into: .pinned(spaceID: spaceID), window: window)
            importTabs(space.favorites.map(\.url), into: .favorites(spaceID: spaceID), window: window)
        }

        if replaceOriginal, let firstImported {
            tabs.setSpace(firstImported, in: window)
            tabs.deleteSpace(original)
        }
    }

    /// No favorites, nothing pinned and at most the one tab a first launch opens.
    private func isUntouchedStarterSpace(_ spaceID: UUID) -> Bool {
        tabs.children(of: .favorites(spaceID: spaceID)).isEmpty
            && tabs.children(of: .pinned(spaceID: spaceID)).isEmpty
            && tabs.children(of: .tabs(spaceID: spaceID)).count <= 1
    }

    /// Tabs and folders in source order. Every insert lands at the top of `parent`, so the
    /// list goes in reversed, folders filled as they are made.
    private func importItems(_ items: [ArcItem], into parent: Parent, window: BrowserWindowState) {
        for item in items.reversed() {
            switch item {
            case .tab(let tab):
                importTabs([tab.url], into: parent, window: window)
            case .folder(let folder):
                guard let folderID = tabs.createFolder(title: folder.title, in: parent, after: nil, open: false) else { continue }
                importItems(folder.items, into: .folder(itemID: folderID), window: window)
            }
        }
    }

    func importDiaData() async {
        let result = await importManager.importDiaData()
        guard let window = importWindow, let spaceID = importSpaceID(window) else { return }

        importTabs(result.favoriteTabs.map(\.url), into: .favorites(spaceID: spaceID), window: window)
        importTabs(result.windowTabs.map(\.url), into: .tabs(spaceID: spaceID), window: window)
    }

    func importSafariData(from directoryURL: URL, importBookmarks: Bool, importHistory: Bool) async {
        let result = await importManager.importSafariData(
            from: directoryURL,
            importBookmarks: importBookmarks,
            importHistory: importHistory
        )

        if !result.bookmarks.isEmpty, let window = importWindow, let spaceID = importSpaceID(window) {
            let favoritesBookmarks = result.bookmarks.filter { $0.folder == "Favorites" }
            let otherBookmarks = result.bookmarks.filter { $0.folder != "Favorites" }

            importTabs(favoritesBookmarks.map(\.url), into: .favorites(spaceID: spaceID), window: window)

            var folderGroups: [String: [SafariBookmark]] = [:]
            var unfolderedBookmarks: [SafariBookmark] = []
            for bookmark in otherBookmarks {
                if let folder = bookmark.folder, !folder.isEmpty {
                    folderGroups[folder, default: []].append(bookmark)
                } else {
                    unfolderedBookmarks.append(bookmark)
                }
            }

            importTabs(unfolderedBookmarks.map(\.url), into: .tabs(spaceID: spaceID), window: window)
            for (folderName, bookmarks) in folderGroups.sorted(by: { $0.key > $1.key }) {
                guard let folderID = tabs.createFolder(title: folderName, in: .pinned(spaceID: spaceID), after: nil, open: false) else { continue }
                importTabs(bookmarks.map(\.url), into: .folder(itemID: folderID), window: window)
            }
        }

        if !result.history.isEmpty {
            let profileId = historyManager.currentProfileId
            historyManager.importVisits(result.history.compactMap { entry in
                guard let url = URL(string: entry.url) else { return nil }
                return HistoryVisit(url: url, title: entry.title, timestamp: entry.visitDate,
                                    tabId: nil, profileId: profileId)
            })
        }
    }

    // MARK: - Helpers

    /// A regular window: intents need one to pick the main tree. Imports never go to a private
    /// window. Onboarding imports run before any browser window registers; an unregistered window
    /// state still targets the main tree, and background opens never select in it.
    private var importWindow: BrowserWindowState? {
        if let active = windowRegistry?.activeWindow, !active.isIncognito { return active }
        return tabs.regularWindows.first ?? BrowserWindowState()
    }

    private func importSpaceID(_ window: BrowserWindowState) -> UUID? {
        window.spaceID ?? tabs.orderedSpaces.first?.id
    }

    /// Adds tabs under `parent` in source order without loading pages or changing selection.
    /// `open` inserts at the top, so the list goes in reversed.
    private func importTabs(_ urls: [String], into parent: Parent, window: BrowserWindowState) {
        for string in urls.reversed() {
            guard let url = URL(string: string), url.scheme != nil else { continue }
            tabs.open(url: url, in: window, placement: .background, parent: parent)
        }
    }
}
