// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserManager+Import.swift
//  Harbor
//

import AppKit
import Foundation
import HarborTabsCore
import HarborWeb
import SwiftUI
import WebKit

extension BrowserManager {
    /// Imports Arc's spaces in Arc's order, each with its own pinned tabs and folders, open tabs,
    /// favorites (from the space's Arc profile) and color. A space Harbor made on first launch
    /// and nobody has used yet is replaced instead of left beside them.
    func importArcData(options: ChromiumImportOptions = ChromiumImportOptions()) async {
        let result = await importManager.importArcSidebarData()
        guard let window = importWindow, let original = importSpaceID(window), !result.spaces.isEmpty else { return }
        let replaceOriginal = isUntouchedStarterSpace(original)

        var lastSpace = tabs.orderedSpaces.last?.id
        var firstImported: UUID?
        var profiles: [(space: UUID, profile: ChromiumProfile)] = []
        let known = ChromiumReader(browser: .arc).profiles()
        for space in result.spaces {
            guard let spaceID = tabs.createSpace(
                name: space.title, icon: space.emoji ?? "person.fill",
                accentHex: space.accentHex ?? "#7C7C7C", after: lastSpace
            ) else { continue }
            lastSpace = spaceID
            firstImported = firstImported ?? spaceID
            profiles.append((spaceID, known.first { $0.directory == space.profileDirectory }
                ?? ChromiumProfile(directory: space.profileDirectory, name: space.title)))
            importTabs(space.unpinned.map(\.url), into: .tabs(spaceID: spaceID), window: window)
            importItems(space.pinned, into: .pinned(spaceID: spaceID), window: window)
            importTabs(space.favorites.map(\.url), into: .favorites(spaceID: spaceID), window: window)
        }

        if replaceOriginal, let firstImported {
            tabs.setSpace(firstImported, in: window)
            tabs.deleteSpace(original)
        }
        await importChromiumData(.arc, targets: profiles, options: options)
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

    func importDiaData(options: ChromiumImportOptions = ChromiumImportOptions()) async {
        let result = await importManager.importDiaData()
        guard let window = importWindow, let spaceID = importSpaceID(window) else { return }

        importTabs(result.favoriteTabs.map(\.url), into: .favorites(spaceID: spaceID), window: window)
        importTabs(result.windowTabs.map(\.url), into: .tabs(spaceID: spaceID), window: window)

        // Dia's first profile goes into this space. Each other profile is its own sign-in context,
        // as an Arc space is, so it becomes a space of its own.
        let profiles = ChromiumReader(browser: .dia).profiles()
        var targets: [(space: UUID, profile: ChromiumProfile)] = []
        var lastSpace = tabs.orderedSpaces.last?.id
        for (index, profile) in profiles.enumerated() {
            if index == 0 {
                targets.append((spaceID, profile))
            } else if let created = tabs.createSpace(name: profile.name, icon: "person.fill", accentHex: "#7C7C7C", after: lastSpace) {
                lastSpace = created
                targets.append((created, profile))
            }
        }
        await importChromiumData(.dia, targets: targets, options: options)
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

    // MARK: - Chromium data

    /// Brings what the person chose into the space each profile became: its accounts (cookies),
    /// history and bookmarks, and its passwords as a CSV for their password manager. The keychain
    /// asks before the key that unlocks cookies and passwords is read, and not at all when neither
    /// was chosen; if the person declines, those two are skipped and the rest still comes over.
    func importChromiumData(
        _ browser: ChromiumBrowser, targets: [(space: UUID, profile: ChromiumProfile)], options: ChromiumImportOptions
    ) async {
        guard browser.isInstalled, !targets.isEmpty, let window = importWindow else { return }
        let reader = ChromiumReader(browser: browser)
        let key = options.needsKey ? await Task.detached { reader.encryptionKey() }.value : nil

        var passwords: [ChromiumLogin] = []
        for (spaceID, profile) in targets {
            let found = await Task.detached {
                (cookies: options.signIns ? key.map { reader.cookies(in: profile, key: $0) } ?? [] : [],
                 logins: options.passwords ? key.map { reader.logins(in: profile, key: $0) } ?? [] : [],
                 history: options.history ? reader.history(in: profile) : [],
                 bookmarks: options.bookmarks ? reader.bookmarks(in: profile) : [])
            }.value

            if let store = tabs.profile(forSpace: spaceID)?.dataStore.httpCookieStore {
                for cookie in found.cookies { await store.setCookie(cookie) }
            }
            historyManager.importVisits(found.history.compactMap { visit in
                URL(string: visit.url).map {
                    HistoryVisit(url: $0, title: visit.title, timestamp: visit.date, tabId: nil, profileId: spaceID)
                }
            })
            if !found.bookmarks.isEmpty {
                func item(_ bookmark: ChromiumBookmark) -> ArcItem {
                    switch bookmark {
                    case .page(let title, let url): return .tab(ArcTab(title: title, url: url))
                    case .folder(let title, let items): return .folder(ArcFolder(title: title, items: items.map(item)))
                    }
                }
                importItems(found.bookmarks.map(item), into: .pinned(spaceID: spaceID), window: window)
            }
            passwords += found.logins
        }
        exportPasswords(passwords, from: browser)
    }

    /// Writes the passwords where the person can import them, readable by them alone, and says so.
    /// Harbor keeps no passwords of its own: a password manager extension, or the Passwords app,
    /// holds them.
    private func exportPasswords(_ logins: [ChromiumLogin], from browser: ChromiumBrowser) {
        guard !logins.isEmpty,
              let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let file = downloads.appendingPathComponent("\(browser.name) passwords.csv")
        guard FileManager.default.createFile(atPath: file.path, contents: Data(PasswordCSV.make(logins).utf8),
                                             attributes: [.posixPermissions: 0o600]) else { return }
        let alert = NSAlert()
        alert.messageText = "Your \(browser.name) passwords are in a file"
        alert.informativeText = "Harbor saved \(logins.count) passwords to “\(file.lastPathComponent)” in Downloads. Import it into Passwords, 1Password or Bitwarden, then delete it: anyone who can open the file can read every password in it."
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([file])
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
