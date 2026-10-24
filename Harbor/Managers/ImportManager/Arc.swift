// Licensed under GPL-3.0. See LICENSE.
//
//  Arc.swift
//  Harbor
//
//  Created by Maciek Bagiński on 29/09/2025.
//
//  Reads Arc's StorableSidebar.json in Arc's own order. Arc keeps one ordered `childrenIds` list
//  per container, spaces in the order of `sidebar.containers[].spaces`, and favorites (top apps)
//  per profile: a space shows the favorites of the profile it belongs to. Read with
//  JSONSerialization rather than Codable so a field Arc adds or renames does not fail the import.
//

import Foundation

// MARK: - Arc Models

struct ArcImportResult {
    let spaces: [ArcSpace]
}

struct ArcSpace {
    let id: String
    let title: String
    /// The Chromium profile folder holding the space's cookies and history: "Default", "Profile 1".
    let profileDirectory: String
    let emoji: String?
    /// The space's theme color as `#RRGGBB`, when Arc has one.
    let accentHex: String?
    /// The favorites of the space's profile.
    let favorites: [ArcTab]
    /// Pinned tabs and folders, in Arc's order.
    let pinned: [ArcItem]
    /// Today's tabs; folders there are flattened, since Harbor's tabs section holds no folders.
    let unpinned: [ArcTab]
}

enum ArcItem {
    case tab(ArcTab)
    case folder(ArcFolder)
}

struct ArcTab {
    let title: String
    let url: String
}

struct ArcFolder {
    let title: String
    let items: [ArcItem]
}

// MARK: - Parser

func parseArcSidebarData(from fileURL: URL) throws -> ArcImportResult {
    let data = try Data(contentsOf: fileURL)
    guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let sidebar = root["sidebar"] as? [String: Any],
          let containers = sidebar["containers"] as? [[String: Any]] else {
        return ArcImportResult(spaces: [])
    }

    var items: [String: [String: Any]] = [:]
    var spaces: [[String: Any]] = []
    var favoritesByProfile: [String: String] = [:]
    for container in containers {
        for case let item as [String: Any] in container["items"] as? [Any] ?? [] {
            if let id = item["id"] as? String { items[id] = item }
        }
        // `spaces` alternates an id string and the space object.
        for case let space as [String: Any] in container["spaces"] as? [Any] ?? [] {
            spaces.append(space)
        }
        // `topAppsContainerIDs` alternates a profile and the id of its favorites container.
        let topApps = container["topAppsContainerIDs"] as? [Any] ?? []
        for index in stride(from: 0, to: topApps.count - 1, by: 2) {
            if let profile = profileKey(topApps[index]), let id = topApps[index + 1] as? String {
                favoritesByProfile[profile] = id
            }
        }
    }

    func children(of id: String?) -> [[String: Any]] {
        guard let id, let ids = items[id]?["childrenIds"] as? [String] else { return [] }
        return ids.compactMap { items[$0] }
    }

    func tab(_ item: [String: Any]) -> ArcTab? {
        guard let data = item["data"] as? [String: Any],
              let tab = data["tab"] as? [String: Any],
              let url = tab["savedURL"] as? String, !url.isEmpty else { return nil }
        let title = (item["title"] as? String) ?? (tab["savedTitle"] as? String) ?? url
        return ArcTab(title: title, url: url)
    }

    func entries(under id: String?) -> [ArcItem] {
        children(of: id).compactMap { item in
            if let tab = tab(item) { return .tab(tab) }
            guard let itemID = item["id"] as? String else { return nil }
            let nested = entries(under: itemID)
            guard !nested.isEmpty else { return nil }
            return .folder(ArcFolder(title: (item["title"] as? String) ?? "Folder", items: nested))
        }
    }

    func flattened(_ entries: [ArcItem]) -> [ArcTab] {
        entries.flatMap { entry -> [ArcTab] in
            switch entry {
            case .tab(let tab): return [tab]
            case .folder(let folder): return flattened(folder.items)
            }
        }
    }

    let result: [ArcSpace] = spaces.compactMap { space in
        guard let id = space["id"] as? String else { return nil }
        // `containerIDs` alternates a kind ("pinned", "unpinned") and the container's id.
        let containerIDs = space["containerIDs"] as? [Any] ?? []
        var sections: [String: String] = [:]
        for index in stride(from: 0, to: containerIDs.count - 1, by: 2) {
            if let kind = containerIDs[index] as? String, let container = containerIDs[index + 1] as? String {
                sections[kind] = container
            }
        }
        let customInfo = space["customInfo"] as? [String: Any]
        let iconType = customInfo?["iconType"] as? [String: Any]
        let favorites = profileKey(space["profile"]).flatMap { favoritesByProfile[$0] }
        return ArcSpace(
            id: id,
            title: (space["title"] as? String) ?? "Space",
            profileDirectory: profileKey(space["profile"]).map(profileDirectory) ?? "Default",
            emoji: iconType?["emoji_v2"] as? String,
            accentHex: accentHex(fromTheme: customInfo?["windowTheme"] as? [String: Any]),
            favorites: flattened(entries(under: favorites)),
            pinned: entries(under: sections["pinned"]),
            unpinned: flattened(entries(under: sections["unpinned"]))
        )
    }
    return ArcImportResult(spaces: result)
}

/// The profile folder a `profileKey` names.
private func profileDirectory(_ key: String) -> String {
    key.hasPrefix("custom:") ? String(key.dropFirst("custom:".count)) : "Default"
}

/// A key that is the same for a space's `profile` and the matching `topAppsContainerIDs` entry:
/// `{"default": true}` or `{"custom": {"_0": {"directoryBasename": "Profile 1"}}}`.
private func profileKey(_ value: Any?) -> String? {
    guard let profile = value as? [String: Any] else { return nil }
    if profile["default"] != nil { return "default" }
    if let custom = profile["custom"] as? [String: Any],
       let inner = custom["_0"] as? [String: Any],
       let name = inner["directoryBasename"] as? String {
        return "custom:\(name)"
    }
    return nil
}

/// The space's theme color: the primary palette's mid tone, else the light foreground color.
private func accentHex(fromTheme theme: [String: Any]?) -> String? {
    guard let theme else { return nil }
    let palette = theme["primaryColorPalette"] as? [String: Any]
    let semantic = ((theme["semanticColorPalette"] as? [String: Any])?["appearanceBased"] as? [String: Any])?["light"] as? [String: Any]
    guard let color = (palette?["midTone"] ?? semantic?["foregroundPrimary"]) as? [String: Any],
          let red = color["red"] as? Double, let green = color["green"] as? Double, let blue = color["blue"] as? Double
    else { return nil }
    func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
    return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
}
