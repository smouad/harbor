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

/// What each browser's import added, so importing the same browser again replaces it instead of
/// adding to it. Going back in onboarding and importing a second time used to double every space.
/// In memory only: it covers the one setup session.
@MainActor
final class ImportLedger {
    struct Entry {
        var spaces: [UUID] = []
        var items: [UUID] = []
    }

    private var entries: [String: Entry] = [:]
    private var recording: String?

    /// Starts recording `browser`'s import and returns what its last import added.
    func begin(_ browser: String) -> Entry {
        recording = browser
        let previous = entries[browser] ?? Entry()
        entries[browser] = Entry()
        return previous
    }

    func end() { recording = nil }

    func add(space: UUID) {
        if let recording { entries[recording, default: Entry()].spaces.append(space) }
    }

    func add(item: UUID) {
        if let recording { entries[recording, default: Entry()].items.append(item) }
    }
}

extension BrowserManager {
    /// Imports Arc's spaces in Arc's order, each with its own pinned tabs and folders, open tabs,
    /// favorites (from the space's Arc profile) and color. A space Harbor made on first launch
    /// and nobody has used yet is replaced instead of left beside them.
    func importArcData(options: ChromiumImportOptions = ChromiumImportOptions()) async {
        let result = await importManager.importArcSidebarData()
        guard let window = importWindow, let original = importSpaceID(window), !result.spaces.isEmpty else { return }
        let replaceOriginal = isUntouchedStarterSpace(original)
        let previous = importLedger.begin("arc")

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
            importLedger.add(space: spaceID)
            // The space's look: Arc's background, gradient and all, as a Harbor theme.
            if let background = space.background {
                tabs.updateSpace(spaceID, name: nil, icon: nil, accentHex: nil, theme: SpaceTheme.imported(
                    colors: background.colors, grain: background.grain ?? 0.5, intensity: background.intensity ?? 0.8))
            }
            profiles.append((spaceID, known.first { $0.directory == space.profileDirectory }
                ?? ChromiumProfile(directory: space.profileDirectory, name: space.title)))
            importNodes(space.unpinned.map { .tab($0) }, into: .tabs(spaceID: spaceID))
            importNodes(space.pinned, into: .pinned(spaceID: spaceID))
            importNodes(space.favorites.map { .tab($0) }, into: .favorites(spaceID: spaceID))
        }

        if replaceOriginal, let firstImported {
            tabs.setSpace(firstImported, in: window)
            tabs.deleteSpace(original)
        }
        await importChromiumData(.arc, targets: profiles, options: options)
        importLedger.end()
        discardImport(previous, replacement: firstImported, window: window)
    }

    /// Removes what an earlier import of the same browser added, once its replacement exists, so the
    /// window never lands on a space that is about to go and there is always a space left.
    private func discardImport(_ previous: ImportLedger.Entry, replacement: UUID?, window: BrowserWindowState) {
        for id in previous.items where tabs.item(id) != nil { tabs.remove(id) }
        if let current = window.spaceID, previous.spaces.contains(current),
           let next = replacement ?? tabs.orderedSpaces.first(where: {
               !previous.spaces.contains($0.id) && $0.id != tabs.agentSpaceID
           })?.id {
            tabs.setSpace(next, in: window)
        }
        for id in previous.spaces where tabs.orderedSpaces.contains(where: { $0.id == id }) { tabs.deleteSpace(id) }
    }

    /// No favorites, nothing pinned and at most the one tab a first launch opens.
    private func isUntouchedStarterSpace(_ spaceID: UUID) -> Bool {
        tabs.children(of: .favorites(spaceID: spaceID)).isEmpty
            && tabs.children(of: .pinned(spaceID: spaceID)).isEmpty
            && tabs.children(of: .tabs(spaceID: spaceID)).count <= 1
    }

    /// Adds Arc-shaped items under `parent` as one edit, folders closed, and records them so a
    /// second import can replace them. A tab with no usable address is left out.
    private func importNodes(_ items: [ArcItem], into parent: Parent) {
        func node(_ item: ArcItem) -> ImportedNode? {
            switch item {
            case .tab(let tab):
                guard let url = URL(string: tab.url), url.scheme != nil else { return nil }
                return .tab(title: tab.title.isEmpty ? (url.host ?? tab.url) : tab.title, url: url)
            case .folder(let folder):
                return .folder(title: folder.title, children: folder.items.compactMap(node))
            }
        }
        for id in tabs.importNodes(items.compactMap(node), into: parent) { importLedger.add(item: id) }
    }

    func importDiaData(options: ChromiumImportOptions = ChromiumImportOptions()) async {
        let result = await importManager.importDiaData()
        guard let window = importWindow, let current = importSpaceID(window) else { return }
        let previous = importLedger.begin("dia")
        // A space an earlier Dia import made is about to go, so this one lands in another.
        let spaceID = previous.spaces.contains(current)
            ? (tabs.orderedSpaces.first { !previous.spaces.contains($0.id) && $0.id != tabs.agentSpaceID }?.id ?? current)
            : current

        importNodes(result.favoriteTabs.map { .tab(ArcTab(title: $0.title, url: $0.url)) }, into: .favorites(spaceID: spaceID))
        importNodes(result.windowTabs.map { .tab(ArcTab(title: $0.title, url: $0.url)) }, into: .tabs(spaceID: spaceID))

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
                importLedger.add(space: created)
                targets.append((created, profile))
            }
        }
        await importChromiumData(.dia, targets: targets, options: options)
        importLedger.end()
        discardImport(previous, replacement: spaceID, window: window)
    }

    func importSafariData(from directoryURL: URL, importBookmarks: Bool, importHistory: Bool) async {
        let result = await importManager.importSafariData(
            from: directoryURL,
            importBookmarks: importBookmarks,
            importHistory: importHistory
        )
        let previous = importLedger.begin("safari")
        defer {
            importLedger.end()
            if let window = importWindow { discardImport(previous, replacement: importSpaceID(window), window: window) }
        }

        if !result.bookmarks.isEmpty, let window = importWindow, let spaceID = importSpaceID(window) {
            let favoritesBookmarks = result.bookmarks.filter { $0.folder == "Favorites" }
            let otherBookmarks = result.bookmarks.filter { $0.folder != "Favorites" }

            func tab(_ bookmark: SafariBookmark) -> ArcItem { .tab(ArcTab(title: bookmark.title, url: bookmark.url)) }
            importNodes(favoritesBookmarks.map(tab), into: .favorites(spaceID: spaceID))

            var folderGroups: [String: [SafariBookmark]] = [:]
            var unfolderedBookmarks: [SafariBookmark] = []
            for bookmark in otherBookmarks {
                if let folder = bookmark.folder, !folder.isEmpty {
                    folderGroups[folder, default: []].append(bookmark)
                } else {
                    unfolderedBookmarks.append(bookmark)
                }
            }

            importNodes(unfolderedBookmarks.map(tab), into: .tabs(spaceID: spaceID))
            importNodes(folderGroups.sorted(by: { $0.key < $1.key }).map { name, bookmarks in
                .folder(ArcFolder(title: name, items: bookmarks.map(tab)))
            }, into: .pinned(spaceID: spaceID))
        }

        if !result.history.isEmpty {
            let profileId = historyManager.currentProfileId
            let cutoff = Date().addingTimeInterval(-Double(ChromiumReader.historyDays) * 86_400)
            historyManager.importVisits(result.history.compactMap { entry in
                guard entry.visitDate >= cutoff, let url = URL(string: entry.url) else { return nil }
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

            if let store = tabs.profile(forSpace: spaceID)?.dataStore.httpCookieStore, let last = found.cookies.last {
                // WebKit takes them in order, so waiting on the last one waits on all.
                for cookie in found.cookies.dropLast() { store.setCookie(cookie, completionHandler: nil) }
                await store.setCookie(last)
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
                importNodes(found.bookmarks.map(item), into: .pinned(spaceID: spaceID))
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
}
