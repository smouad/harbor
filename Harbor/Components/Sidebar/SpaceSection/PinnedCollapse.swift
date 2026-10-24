// Licensed under GPL-3.0. See LICENSE.
//
//  PinnedCollapse.swift
//  Harbor
//
//  Which spaces have folded their pinned section away under the space's name. A view setting of
//  this Mac, so it lives in the defaults and not in the tab files.
//

import Foundation
import Observation

@MainActor
@Observable
final class PinnedCollapse {
    static let shared = PinnedCollapse()
    private static let key = "sidebar.collapsedPinned"

    private(set) var collapsed: Set<UUID>

    private init() {
        collapsed = Set((UserDefaults.standard.stringArray(forKey: Self.key) ?? []).compactMap(UUID.init))
    }

    func isCollapsed(_ spaceID: UUID) -> Bool { collapsed.contains(spaceID) }

    func toggle(_ spaceID: UUID) {
        if collapsed.contains(spaceID) { collapsed.remove(spaceID) } else { collapsed.insert(spaceID) }
        UserDefaults.standard.set(collapsed.map(\.uuidString), forKey: Self.key)
    }
}
