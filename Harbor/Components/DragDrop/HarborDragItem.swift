// Licensed under GPL-3.0. See LICENSE.
//
//  HarborDragItem.swift
//  Harbor
//

import Foundation
import AppKit
import HarborTabsCore
import UniformTypeIdentifiers

extension UTType {
    static let harborTabItem = UTType(exportedAs: "com.harbor.tab-drag-item")
}

extension NSPasteboard.PasteboardType {
    static let harborTabItem = NSPasteboard.PasteboardType("com.harbor.tab-drag-item")
}

// MARK: - Drop Zone Identity

/// A place a dragged item can land.
enum DropZoneID: Hashable {
    /// A space's favorites grid.
    case favorites(spaceID: UUID)
    /// The rows of a sidebar section (`.pinned` or `.tabs`).
    case section(Parent)
    /// A target without rows (space title, space switcher) that receives the item as a whole.
    case target(Parent)
}

// MARK: - Drag Item

struct HarborDragItem: Codable, Equatable {
    /// The dragged `Item` id (name kept for existing pasteboard readers).
    let tabId: UUID
    var title: String
    var urlString: String

    init(tabId: UUID, title: String, urlString: String = "") {
        self.tabId = tabId
        self.title = title
        self.urlString = urlString
    }
}

extension HarborDragItem {
    func writeToPasteboard(_ pasteboard: NSPasteboard) {
        pasteboard.declareTypes([.harborTabItem, .string], owner: nil)
        do {
            let data = try JSONEncoder().encode(self)
            pasteboard.setData(data, forType: .harborTabItem)
        } catch {
            NSLog("HarborDragItem encoding failed: %@", String(describing: error))
        }
        pasteboard.setString(tabId.uuidString, forType: .string)
    }

    static func fromPasteboard(_ pasteboard: NSPasteboard) -> HarborDragItem? {
        guard let data = pasteboard.data(forType: .harborTabItem) else { return nil }
        return try? JSONDecoder().decode(HarborDragItem.self, from: data)
    }
}
