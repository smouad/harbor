// Licensed under GPL-3.0. See LICENSE.
//
//  TabsController+Import.swift
//  HarborWeb
//
//  Adding a whole imported tree of tabs and folders as one edit.
//

import Foundation
import HarborTabsCore

/// A tab or folder an import brings in, in the order the person had them.
public indirect enum ImportedNode {
    case tab(title: String, url: URL)
    case folder(title: String, children: [ImportedNode])
}

extension TabsController {
    private struct NothingImported: Error {}

    /// Adds `nodes` at the top of `parent`, in order, folders filled as they are made, and returns the
    /// id of every tab and folder it made. One edit rather than one per tab: each `open` copies the
    /// tree, checks it against saved state and schedules a save, so importing a few hundred tabs
    /// one at a time did quadratic work on the main thread and the window stalled. A node the tree
    /// refuses (a folder nested too deep) is skipped. The import is not an undo step.
    @discardableResult
    public func importNodes(_ nodes: [ImportedNode], into parent: Parent) -> [UUID] {
        let owner: Owner?
        switch parent {
        case .favorites(let spaceID), .pinned(let spaceID), .tabs(let spaceID): owner = self.owner(ofSpace: spaceID)
        case .folder(let folderID): owner = self.owner(ofItem: folderID)
        }
        guard let owner, !nodes.isEmpty else { return [] }
        var created: [UUID] = []
        _ = perform(owner, "import", undoable: false) { tree in
            // One level at a time: its tabs and folders go in as a batch, then each folder's contents.
            func add(_ nodes: [ImportedNode], into parent: Parent) {
                var level: [TabTree.NewItem] = []
                var folders: [(id: UUID, children: [ImportedNode])] = []
                for node in nodes {
                    let id = UUID()
                    switch node {
                    case .tab(let title, let url):
                        level.append(.tab(id: id, url: url, title: title))
                    case .folder(let title, let children):
                        level.append(.folder(id: id, title: title))
                        folders.append((id, children))
                    }
                }
                if (try? tree.createBatch(level, in: parent)) == nil {
                    // The tree refused the level (a folder nested too deep): keep its tabs.
                    let tabsOnly = level.filter { if case .tab = $0 { return true } else { return false } }
                    guard (try? tree.createBatch(tabsOnly, in: parent)) != nil else { return }
                    folders = []
                    level = tabsOnly
                }
                created += level.map {
                    switch $0 {
                    case .tab(let id, _, _), .folder(let id, _): return id
                    }
                }
                for folder in folders { add(folder.children, into: .folder(itemID: folder.id)) }
            }
            add(nodes, into: parent)
            guard !created.isEmpty else { throw NothingImported() }
            return Change()
        }
        return created
    }
}
