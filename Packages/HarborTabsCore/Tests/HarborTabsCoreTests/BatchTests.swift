// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
@testable import HarborTabsCore

struct BatchTests {
    @Test func batchPutsNewItemsAtTheTopInOrderAndKeepsTheOldOnesAfter() throws {
        var f = Fixture()
        let tabs = Parent.tabs(spaceID: f.spaceA)
        let existing = f.tab("old", in: tabs)
        let ids = (0..<300).map { _ in UUID() }
        let items = ids.enumerated().map { TabTree.NewItem.tab(id: $1, url: URL(string: "https://example.com/\($0)")!, title: "t\($0)") }

        _ = try f.tree.createBatch(items, in: tabs)

        let order = f.tree.children(of: tabs).map(\.id)
        #expect(Array(order.prefix(300)) == ids)
        #expect(order.last == existing)
        #expect(order.count == 301)
    }

    @Test func batchFoldersTakeTheirOwnBatch() throws {
        var f = Fixture()
        let pinned = Parent.pinned(spaceID: f.spaceA)
        let folder = UUID()
        _ = try f.tree.createBatch([.folder(id: folder, title: "F")], in: pinned)
        _ = try f.tree.createBatch([
            .tab(id: UUID(), url: URL(string: "https://a.test/")!, title: "a"),
            .tab(id: UUID(), url: URL(string: "https://b.test/")!, title: "b"),
        ], in: .folder(itemID: folder))

        #expect(f.tree.children(of: .folder(itemID: folder)).map(\.displayTitle) == ["a", "b"])
        #expect(f.tree.item(folder)?.isFolder == true)
    }

    @Test func batchObeysTheSameRulesAsCreateFolder() {
        var f = Fixture()
        // Favorites hold tabs only.
        #expect(throws: (any Error).self) {
            _ = try f.tree.createBatch([.folder(id: UUID(), title: "no")], in: .favorites(spaceID: f.spaceA))
        }
        // An empty batch changes nothing.
        #expect((try? f.tree.createBatch([], in: .tabs(spaceID: f.spaceA)))?.isEmpty == true)
    }
}
