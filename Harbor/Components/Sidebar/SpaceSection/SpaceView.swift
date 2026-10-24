// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 04/08/2025.
//
//  A space's sidebar outline: pinned section rows, the separator and new-tab button, then
//  tabs section rows. Rows come flattened from `TabsController.rows(space:)`; each section is
//  one drop zone whose rows all share `Size.row` height and `Spacing.rowGap` spacing, which the
//  drop position math in `HarborDragSessionManager` relies on.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

struct SpaceView: View {
    let spaceID: UUID
    let isActive: Bool
    @Binding var isSidebarHovered: Bool

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(TabOrganizerManager.self) private var tabOrganizerManager
    @Environment(\.harborSettings) private var harborSettings
    @ObservedObject private var dragSession = HarborDragSessionManager.shared
    @State private var isNewTabHovering = false

    init(spaceID: UUID, isActive: Bool, isSidebarHovered: Binding<Bool>) {
        self.spaceID = spaceID
        self.isActive = isActive
        self._isSidebarHovered = isSidebarHovered
    }

    private var tabs: TabsController { browserManager.tabs }

    private var outerWidth: CGFloat {
        let visibleWidth = windowState.sidebarWidth
        if visibleWidth > 0 {
            return visibleWidth
        }
        return max(browserManager.getSavedSidebarWidth(for: windowState), 0)
    }

    private var innerWidth: CGFloat {
        max(outerWidth - HarborDesign.Spacing.sidebarInset * 2, 0)
    }

    var body: some View {
        let rows = tabs.rows(space: spaceID)
        let pinned = rows.filter { $0.section == .pinned }
        let regular = rows.filter { $0.section == .tabs }
        let split = splitPair(in: rows)
        // Folded under the space's name.
        let folded = PinnedCollapse.shared.isCollapsed(spaceID)

        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: HarborDesign.Spacing.sectionGap) {
                // An empty pinned section shows a drop slot only while a drag is on.
                if (!pinned.isEmpty && !folded) || dragSession.isDragging {
                    sectionList(.pinned(spaceID: spaceID), rows: pinned, split: split, showsTail: false)
                        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
                }

                VStack(spacing: HarborDesign.Spacing.sectionGap) {
                    separatorAndNewTab(regular: regular)
                    sectionList(.tabs(spaceID: spaceID), rows: regular, split: split, showsTail: true)
                }
            }
            .animation(HarborDesign.Motion.standard, value: (pinned.isEmpty || folded) && !dragSession.isDragging)
            .frame(minWidth: 0, maxWidth: innerWidth, alignment: .leading)
        }
        .contentShape(Rectangle())
        .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
        .frame(minWidth: 0, maxWidth: outerWidth, alignment: .leading)
    }

    // MARK: - Sections

    private func sectionList(_ section: Parent, rows allRows: [Row], split: SplitPair?, showsTail: Bool) -> some View {
        // The pair is one row at its anchor; the other half's own row is hidden.
        let rows = split.map { split in allRows.filter { !split.contains($0.id) || $0.id == split.anchorID } } ?? allRows
        let zone = DropZoneID.section(section)
        let position = dragSession.dropPosition?.zone == zone ? dragSession.dropPosition : nil
        return HarborDropZoneHostView(
            zoneID: zone,
            layout: .rows(rows),
            manager: dragSession,
            onDrop: { itemID, position in
                tabs.drop(itemID, at: position, section: section, rows: rows)
            }
        ) {
            VStack(spacing: HarborDesign.Spacing.rowGap) {
                LazyVStack(spacing: HarborDesign.Spacing.rowGap) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowView(row, zone: zone, split: split, isDropTarget: position == DropPosition(zone: zone, index: index, placement: .into))
                            .padding(.leading, CGFloat(row.depth) * HarborDesign.Spacing.folderIndent)
                            // The line is indented to the level the drop lands at (dropDepth), so a
                            // line that puts the item inside a folder is always drawn inside it.
                            .overlay(alignment: .top) {
                                if position == DropPosition(zone: zone, index: index, placement: .before) {
                                    dropLine.offset(y: -HarborDesign.Spacing.rowGap)
                                        .padding(.leading, dropLineIndent)
                                }
                            }
                            .overlay(alignment: .bottom) {
                                if position == DropPosition(zone: zone, index: index, placement: .after)
                                    || (index == rows.count - 1 && position == DropPosition(zone: zone, index: rows.count, placement: .before)) {
                                    dropLine.offset(y: HarborDesign.Spacing.rowGap)
                                        .padding(.leading, dropLineIndent)
                                }
                            }
                    }
                }

                if allRows.isEmpty, !showsTail {
                    emptySectionSlot(isActive: dragSession.activeZone == zone)
                }

                if showsTail {
                    Color.clear
                        .contentShape(Rectangle())
                        .conditionalWindowDrag()
                        .frame(minHeight: HarborDesign.Size.dropTail, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 0, maxWidth: innerWidth, alignment: .leading)
            .contentShape(Rectangle())
            // Rows have their own menus; this one covers the gaps and the tail of the section.
            .contextMenu {
                Button {
                    tabs.createFolderForRename(in: section, after: tabs.children(of: section).last?.id)
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
            }
        }
    }

    private func emptySectionSlot(isActive: Bool) -> some View {
        HarborDesign.Radius.shape(HarborDesign.Radius.md)
            .strokeBorder(style: StrokeStyle(lineWidth: HarborDesign.Size.hairlineWidth, dash: [HarborDesign.Spacing.sm, HarborDesign.Spacing.xs]))
            .foregroundStyle(isActive ? HarborDesign.Surface.dropBorderActive : HarborDesign.Surface.dropBorderIdle)
            .background(HarborDesign.Radius.shape(HarborDesign.Radius.md).fill(isActive ? HarborDesign.Surface.fillPressed : Color.clear))
            .frame(height: HarborDesign.Size.row)
            .animation(HarborDesign.Motion.quick, value: isActive)
    }

    /// Leading inset of a drop line. The overlay spans the row including its depth padding.
    private var dropLineIndent: CGFloat {
        CGFloat(dragSession.dropDepth) * HarborDesign.Spacing.folderIndent
    }

    private var dropLine: some View {
        Rectangle()
            .fill(HarborDesign.Surface.dropBorderActive)
            .frame(height: HarborDesign.Spacing.rowGap)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func rowView(_ row: Row, zone: DropZoneID, split: SplitPair?, isDropTarget: Bool) -> some View {
        if let split, row.id == split.anchorID {
            SplitTabRow(left: split.left, right: split.right, zoneID: zone)
        } else {
            let session = tabs.session(for: row.item.id)
            HarborDragSourceView(
                item: HarborDragItem(tabId: row.item.id, title: tabs.title(for: row.item), urlString: tabs.currentURL(for: row.item)?.absoluteString ?? ""),
                icon: row.item.isFolder ? Image(systemName: "folder.fill") : session?.favicon,
                zoneID: zone,
                manager: dragSession
            ) {
                if row.item.isFolder {
                    TabFolderView(item: row.item, spaceID: spaceID, isDropTarget: isDropTarget)
                } else {
                    SpaceTab(item: row.item, hasChildren: row.hasChildren)
                }
            }
            .opacity(dragSession.draggedItem?.tabId == row.item.id ? HarborDesign.Surface.unloadedOpacity : 1)
            .id(row.item.id)
        }
    }

    // MARK: - Split

    private struct SplitPair {
        let left: Item
        let right: Item
        /// The row the pair is drawn at.
        let anchorID: UUID

        func contains(_ id: UUID) -> Bool { id == left.id || id == right.id }
    }

    /// The window's split pair, anchored at the left tab's row, or the right tab's when the left
    /// has no visible row (a favorite, or inside a closed folder).
    private func splitPair(in rows: [Row]) -> SplitPair? {
        guard let split = windowState.split,
              let left = tabs.item(split.leftItemID), let right = tabs.item(split.rightItemID),
              let anchor = [left.id, right.id].first(where: { id in rows.contains { $0.id == id } })
        else { return nil }
        return SplitPair(left: left, right: right, anchorID: anchor)
    }

    // MARK: - Separator and New Tab

    private func separatorAndNewTab(regular: [Row]) -> some View {
        let looseTabs = regular.filter { $0.depth == 0 && !$0.item.isFolder }.map(\.item.id)
        return VStack(spacing: HarborDesign.Spacing.xs) {
            SpaceSeparator(
                isHovering: $isSidebarHovered,
                // Clear empties the section: a tab goes with its whole trail.
                onClear: { looseTabs.forEach(tabs.remove) },
                onOrganize: harborSettings.tabOrganizerEnabled && tabOrganizerManager.isAvailable ? {
                    Task {
                        await tabOrganizerManager.organizeTabs(in: spaceID, using: tabs)
                    }
                } : nil,
                isOrganizing: tabOrganizerManager.isOrganizing,
                tabCount: looseTabs.count
            )
            .padding(.horizontal, HarborDesign.Spacing.md)

            newTabButton
        }
    }

    private var newTabButton: some View {
        Button {
            commandPalette.open()
        } label: {
            HStack(spacing: HarborDesign.Spacing.md) {
                Image(systemName: "plus")
                    .font(.system(size: HarborDesign.Size.favicon, weight: .medium))
                Text("New Tab")
                    .font(HarborDesign.Font.body)
                Spacer(minLength: 0)
                if isNewTabHovering {
                    Text("⌘T")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isNewTabHovering ? .secondary : .tertiary)
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.row)
            .frame(maxWidth: .infinity)
            .background(isNewTabHovering ? HarborDesign.Surface.fill : Color.clear)
            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
        .buttonStyle(.plain)
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) { isNewTabHovering = hovering }
        }
    }
}
