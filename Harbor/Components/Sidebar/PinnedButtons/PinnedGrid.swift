// Licensed under GPL-3.0. See LICENSE.
//
//      PinnedGrid.swift
//      Harbor
//
//      Created by Maciek Bagiński on 30/07/2025.
//
import SwiftUI
import UniformTypeIdentifiers
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

struct PinnedGrid: View {
    let spaceID: UUID?

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(WindowRegistry.self) private var windowRegistry
    @ObservedObject private var dragSession = HarborDragSessionManager.shared
    /// Arc's grid: four across at the default width, fewer when the sidebar is narrower.
    private let maxColumns = 4

    init(spaceID: UUID? = nil) {
        self.spaceID = spaceID
    }

    /// Read here, in the grid's own body: a page is a cached hosting view, so a width passed in
    /// from the parent's body only reached it by rebuilding the whole page on every pixel of a
    /// resize, which reset each tile's favicon to the placeholder.
    private var width: CGFloat { windowState.sidebarContentWidth }

    private var tabs: TabsController { browserManager.tabs }

    @ViewBuilder
    var body: some View {
        let effectiveSpaceID = spaceID ?? windowState.spaceID
        let items: [Item] = effectiveSpaceID.map { tabs.favorites(of: $0) } ?? []
        let colsCount: Int = columnCount(for: width, itemCount: items.count)

        let shouldAnimate = (windowRegistry.activeWindow?.id == windowState.id) && !browserManager.isSwitchingSpace

        if let spaceID = effectiveSpaceID {
            let zone = DropZoneID.favorites(spaceID: spaceID)
            if items.isEmpty {
                let isDragging = dragSession.isDragging

                HarborDropZoneHostView(
                    zoneID: zone,
                    layout: .grid(count: 0, columns: colsCount),
                    manager: dragSession,
                    onDrop: { id, position in tabs.dropOnFavorites(id, spaceID: spaceID, index: position.index) }
                ) {
                    VStack(spacing: HarborDesign.Spacing.md) {
                        Image(systemName: "star.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)

                        VStack(spacing: HarborDesign.Spacing.xxs) {
                            Text("Drag to add Favorites")
                                .font(HarborDesign.Font.label)
                                .foregroundStyle(.secondary)

                            Text("Favorites keep your most\nused sites and apps close")
                                .font(HarborDesign.Font.secondary)
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HarborDesign.Spacing.xl)
                    .padding(.horizontal, HarborDesign.Spacing.lg)
                    .background {
                        HarborDesign.Radius.shape(HarborDesign.Radius.lg)
                            .strokeBorder(style: StrokeStyle(lineWidth: HarborDesign.Size.hairlineWidth, dash: [HarborDesign.Spacing.sm, HarborDesign.Spacing.xs]))
                            .foregroundStyle(isDragging ? HarborDesign.Surface.dropBorderActive : HarborDesign.Surface.dropBorderIdle)
                    }
                    .background {
                        HarborDesign.Radius.shape(HarborDesign.Radius.lg)
                            .fill(isDragging ? HarborDesign.Surface.fillPressed : Color.clear)
                    }
                    .animation(HarborDesign.Motion.quick, value: isDragging)
                }
            } else {
                HarborDropZoneHostView(
                    zoneID: zone,
                    layout: .grid(count: items.count, columns: colsCount),
                    manager: dragSession,
                    onDrop: { id, position in tabs.dropOnFavorites(id, spaceID: spaceID, index: position.index) }
                ) {
                    // Not a lazy grid: a lazy one reports no height until its second layout pass, so a
                    // page built a moment before it slid in showed its tabs too high and then dropped
                    // them when the favorites appeared.
                    // Each tile is given its share of the width outright: a grid sizes a column from
                    // its content's ideal width, and the first tile took the whole row.
                    let tileWidth = max(1, floor((width - HarborDesign.Spacing.tileGap * CGFloat(colsCount - 1)) / CGFloat(colsCount)))
                    Grid(horizontalSpacing: HarborDesign.Spacing.tileGap, verticalSpacing: HarborDesign.Spacing.tileGap) {
                        let insertionIdx = insertionIndex(in: zone, items: items)
                        let cells = gridCells(items: items, insertion: insertionIdx)

                        ForEach(Array(stride(from: 0, to: cells.count, by: colsCount)), id: \.self) { start in
                            GridRow {
                                ForEach(cells[start..<min(start + colsCount, cells.count)]) { cell in
                                    switch cell.kind {
                                    case let .tile(item):
                                        PinnedTile(item: item, zone: zone)
                                            .opacity(dragSession.draggedItem?.tabId == item.id ? 0.0 : 1.0)
                                            .frame(width: tileWidth)
                                    case .placeholder:
                                        essentialsPlaceholder
                                            .frame(width: tileWidth)
                                    }
                                }
                                // A last row with fewer tiles keeps the same column widths.
                                ForEach(0..<(colsCount - min(colsCount, cells.count - start)), id: \.self) { _ in
                                    Color.clear.frame(width: tileWidth, height: 0)
                                }
                            }
                        }
                    }
                    .animation(HarborDesign.Motion.spring, value: insertionIndex(in: zone, items: items))
                }
                .contentShape(Rectangle())
                .fixedSize(horizontal: false, vertical: true)
                .animation(shouldAnimate ? HarborDesign.Motion.standard : nil, value: colsCount)
                .animation(shouldAnimate ? HarborDesign.Motion.standard : nil, value: items.count)
                .allowsHitTesting(!browserManager.isSwitchingSpace)
            }
        }
    }

    /// One cell of the favorites grid: a tile, or the gap a dragged tile will drop into.
    private struct GridCell: Identifiable {
        enum Kind { case tile(Item), placeholder }
        let id: String
        let kind: Kind
    }

    private func gridCells(items: [Item], insertion: Int?) -> [GridCell] {
        var cells: [GridCell] = []
        for (index, item) in items.enumerated() {
            let isDraggedItem = dragSession.draggedItem?.tabId == item.id
            if let insertion, insertion == index, !isDraggedItem {
                cells.append(GridCell(id: "gap", kind: .placeholder))
            }
            cells.append(GridCell(id: item.id.uuidString, kind: .tile(item)))
        }
        if let insertion, insertion >= items.count {
            cells.append(GridCell(id: "gap", kind: .placeholder))
        }
        return cells
    }

    /// The insertion index for the grid during a drag, or nil when no placeholder should show.
    private func insertionIndex(in zone: DropZoneID, items: [Item]) -> Int? {
        guard dragSession.isDragging, dragSession.activeZone == zone,
              let position = dragSession.dropPosition, position.zone == zone else {
            return nil
        }
        // Reordering within the grid: no placeholder at the dragged tile's own slot.
        if dragSession.sourceZone == zone,
           let dragged = dragSession.draggedItem?.tabId,
           let from = items.firstIndex(where: { $0.id == dragged }),
           position.index == from || position.index == from + 1 {
            return nil
        }
        return position.index
    }

    private var essentialsPlaceholder: some View {
        HarborDesign.Radius.shape(HarborDesign.Radius.tile)
            .fill(HarborDesign.Surface.fillPressed)
            .frame(minWidth: HarborDesign.Size.essentialsTile, minHeight: HarborDesign.Size.essentialsTile)
    }

    private func columnCount(for width: CGFloat, itemCount: Int) -> Int {
        guard width > 0, itemCount > 0 else { return 1 }
        var cols = min(maxColumns, itemCount)
        while cols > 1 {
            let needed = CGFloat(cols) * HarborDesign.Size.essentialsTile + CGFloat(cols - 1) * HarborDesign.Spacing.tileGap
            if needed <= width { break }
            cols -= 1
        }
        return max(1, cols)
    }
}

private struct PinnedTile: View {
    let item: Item
    let zone: DropZoneID

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @ObservedObject private var dragSession = HarborDragSessionManager.shared

    private var tabs: TabsController { browserManager.tabs }

    var body: some View {
        let session = tabs.session(for: item.id)
        let url = tabs.currentURL(for: item)?.absoluteString ?? ""
        HarborDragSourceView(
            item: HarborDragItem(tabId: item.id, title: tabs.title(for: item), urlString: url),
            icon: session?.favicon,
            zoneID: zone,
            manager: dragSession
        ) {
            PinnedTabView(
                tabName: tabs.title(for: item),
                tabURL: url,
                tabIcon: ItemFavicon(item: item, session: session).environment(tabs),
                isActive: tabs.selectedItemID(in: windowState) == item.id,
                isUnloaded: session?.isUnloaded ?? true,
                hasLeftPinnedURL: tabs.hasLeftHome(item.id),
                onResetToPinnedURL: { tabs.resetToHome(item.id) },
                action: {
                    FavoritePreview.shared.dismiss()
                    tabs.select(item.id, in: windowState)
                }
            )
            .frame(maxWidth: .infinity)
            .anchorPreference(key: FavoritePreviewAnchorKey.self, value: .bounds) {
                FavoritePreview.shared.itemID == item.id && FavoritePreview.shared.windowID == windowState.id ? $0 : nil
            }
            .contextMenu {
                TabContextMenu(itemID: item.id, context: .favorite)
                    .environment(windowState)
                    .environment(tabs)
                    .environment(\.tabActions, browserManager)
            }
            .onHoverTracking { hovering in
                browserManager.hoveredPinnedTabId = hovering ? item.id : nil
                FavoritePreview.shared.tileHover(item, hovering: hovering, in: windowState, tabs: tabs)
            }
        }
    }
}
