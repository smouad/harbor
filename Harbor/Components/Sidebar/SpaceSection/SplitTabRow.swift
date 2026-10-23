// Licensed under GPL-3.0. See LICENSE.
import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborUI
import HarborWeb

/// The window's split pair shown as one sidebar row (from `BrowserWindowState.split`).
/// The halves' visuals are `SplitHalfLabel` in HarborUI; this file is the drag source around them.
struct SplitTabRow: View {
    let left: Item
    let right: Item
    /// The drop zone the halves drag from.
    let zoneID: DropZoneID

    @Environment(BrowserWindowState.self) private var windowState

    /// The whole row is the selection while the window shows the pair.
    private var isActive: Bool {
        windowState.selectedItemID == left.id || windowState.selectedItemID == right.id
    }

    var body: some View {
        HStack(spacing: 0) {
            SplitHalfTab(item: left, zoneID: zoneID)
            Rectangle()
                .fill(HarborDesign.Surface.hairline)
                .frame(width: HarborDesign.Size.hairlineWidth)
                .padding(.vertical, HarborDesign.Spacing.sm)
            SplitHalfTab(item: right, zoneID: zoneID)
        }
        .frame(height: HarborDesign.Size.row)
        .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .harborRowSelection(isActive)
        .harborElevation(isActive ? .raised : .flat)
    }
}

private struct SplitHalfTab: View {
    let item: Item
    let zoneID: DropZoneID

    @Environment(TabsController.self) private var tabs
    @ObservedObject private var dragSession = HarborDragSessionManager.shared

    var body: some View {
        let session = tabs.session(for: item.id)
        HarborDragSourceView(
            item: HarborDragItem(tabId: item.id, title: tabs.title(for: item), urlString: tabs.currentURL(for: item)?.absoluteString ?? ""),
            icon: session?.favicon,
            zoneID: zoneID,
            manager: dragSession
        ) {
            SplitHalfLabel(item: item)
        }
        .opacity(dragSession.draggedItem?.tabId == item.id ? HarborDesign.Surface.unloadedOpacity : 1)
    }
}
