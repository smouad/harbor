// Licensed under GPL-3.0. See LICENSE.
//
//  ItemFavicon.swift
//  HarborUI
//
//  The favicon every row and tile draws, and the inline-rename state the rows and the
//  context menu share.
//

import SwiftUI
import HarborTabsCore
import HarborWeb

// MARK: - Rename State

/// The row being renamed inline. Shared so a context menu can start a rename on its row.
@MainActor
@Observable
final class SidebarRenameState {
    static let shared = SidebarRenameState()
    var itemID: UUID?
}

extension TabsController {
    /// Creates a "New Folder" under `parent` after `after` and starts renaming it inline.
    public func createFolderForRename(in parent: Parent, after: UUID?) {
        guard let folderID = createFolder(title: "New Folder", in: parent, after: after) else { return }
        if case .folder(let outer) = parent { openFolder(outer) }
        SidebarRenameState.shared.itemID = folderID
    }
}

// MARK: - Favicon

/// A row or tile favicon: the live page's, else the cached one for the item's host, else a globe.
public struct ItemFavicon: View {
    let item: Item
    let session: PageSession?
    // Optional: a view hosted in AppKit may not inherit it, and a row then only reads the cache.
    @Environment(TabsController.self) private var tabs: TabsController?
    @State private var cached: Image?

    public init(item: Item, session: PageSession?) {
        self.item = item
        self.session = session
    }

    public var body: some View {
        (session?.favicon ?? cached ?? Image(systemName: "globe"))
            .resizable()
            .scaledToFit()
            // Keyed on the session too: closing a pinned tab or favorite ends its page but keeps
            // the row, and the cached icon must be loaded then.
            .task(id: "\(item.url?.host ?? "")|\(session == nil)") {
                session?.ensureFaviconLoaded()
                guard let host = item.url?.host else { return }
                // With no page open, ask the site for its icon, unless the row is in a private
                // window, whose hosts must not reach the shared cache or the network.
                let image: PlatformImage?
                if session == nil, let tabs, !tabs.isInPrivateWindow(item.id) {
                    image = await FaviconCache.shared.loadOrFetch(host: host)
                } else {
                    image = await FaviconCache.shared.cachedImage(for: host)
                }
                guard let image else { return }
                cached = Image(platformImage: image)
            }
    }
}
