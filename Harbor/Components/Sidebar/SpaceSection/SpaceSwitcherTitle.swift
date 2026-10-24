// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceSwitcherTitle.swift
//  Harbor
//
//  The current space's name in the traffic-light row. Clicking it lists every space.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

struct SpaceSwitcherTitle: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.harborSettings) private var harborSettings
    @Environment(\.openSettings) private var openSettings
    @ObservedObject private var dragSession = HarborDragSessionManager.shared
    @State private var isHovering = false
    @State private var showsThemeEditor = false
    @State private var isRowHovered = false
    @State private var isRenaming = false
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool
    @Environment(\.tabActions) private var actions

    /// The space to name; nil names the window's space. A sidebar page names its own, so the
    /// title moves with the page during a swipe.
    var spaceID: UUID? = nil
    let onNewSpace: () -> Void
    /// The "…" at the row's trailing edge, with the space's own actions: rename, theme, folders,
    /// delete. Only the title heading a space's tabs has it.
    var showsActions = false

    private var currentSpace: SpaceRecord? {
        (spaceID ?? windowState.spaceID).flatMap { tabs.space($0) }
    }

    var body: some View {
        if let space = currentSpace {
            // Also the pin target for a space whose pinned section is empty.
            let pinned = Parent.pinned(spaceID: space.id)
            HarborDropZoneHostView(zoneID: .target(pinned), manager: dragSession, onDrop: { itemID in
                tabs.pin(itemID, to: pinned)
            }) {
                HStack(spacing: 0) {
                    if isRenaming {
                        renameField(space)
                    } else {
                        titleContent(space)
                    }
                    if showsActions, windowState.privateTree == nil, !space.isAgent, !isRenaming {
                        Spacer(minLength: HarborDesign.Spacing.sm)
                        actionsMenu(space)
                    }
                }
                .padding(.trailing, showsActions ? HarborDesign.Spacing.xs : 0)
                // As the URL bar draws itself: one rounded fill under the whole row.
                .harborControlSurface(showsActions && (isRowHovered || isDropTarget(space)), in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
                .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
                .onHoverTracking { isRowHovered = $0 }
                .popover(isPresented: $showsThemeEditor, arrowEdge: .bottom) {
                    SpaceThemeEditor(theme: themeBinding(space)) {
                        tabs.updateSpace(space.id, name: nil, icon: nil, accentHex: nil, clearTheme: true)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func titleContent(_ space: SpaceRecord) -> some View {
        if windowState.privateTree != nil {
            label(space)
        } else if showsActions {
            // Heading the space's tabs, the name folds the pinned section away and back.
            let folded = PinnedCollapse.shared.isCollapsed(space.id)
            Button {
                withAnimation(HarborDesign.Motion.standard) { PinnedCollapse.shared.toggle(space.id) }
            } label: {
                HStack(spacing: 0) {
                    Image(systemName: "chevron.right")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(folded ? 0 : 90))
                        .frame(width: HarborDesign.Size.rowGlyph)
                        .padding(.leading, HarborDesign.Spacing.sm)
                    label(space)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                menuContent(current: space)
            } label: {
                label(space)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            // Width may shrink so a long name truncates beside the history buttons.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Rename

    /// Renaming happens in the row itself: the name becomes a field with a Done button.
    private func renameField(_ space: SpaceRecord) -> some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            TextField("Space name", text: $draftName)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.label)
                .focused($renameFocused)
                .onSubmit { commitRename(space) }
                .onExitCommand { isRenaming = false }
            Button("Done") { commitRename(space) }
                .buttonStyle(.plain)
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, HarborDesign.Spacing.sm)
        .frame(height: HarborDesign.Size.row)
        .onAppear { renameFocused = true }
    }

    private func beginRename(_ space: SpaceRecord) {
        draftName = space.name
        isRenaming = true
    }

    private func commitRename(_ space: SpaceRecord) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty, name != space.name {
            tabs.updateSpace(space.id, name: name, icon: nil, accentHex: nil)
        }
        isRenaming = false
    }

    // MARK: - Actions

    private func actionsMenu(_ space: SpaceRecord) -> some View {
        Menu {
            // Every space, to move between them from here: the name itself now folds the tabs.
            ForEach(tabs.switchableSpaces(for: windowState)) { other in
                Button {
                    tabs.setSpace(other.id, in: windowState)
                } label: {
                    if other.id == space.id {
                        Label(other.name, systemImage: "checkmark")
                    } else {
                        Text(other.name)
                    }
                }
            }
            Button("New Space…", systemImage: "plus", action: onNewSpace)
            Divider()
            Button("Rename Space…") { beginRename(space) }
            Button("Edit Theme Color…") { showsThemeEditor = true }
            Divider()
            Button("New Folder") {
                tabs.createFolderForRename(in: .tabs(spaceID: space.id), after: nil)
            }
            Menu("Live Folders") {
                ForEach(LiveFolderMenuItem.all, id: \.title) { entry in
                    Button(entry.title, systemImage: entry.symbol) {
                        tabs.createLiveFolder(entry.source, in: space.id)
                    }
                }
            }
            Divider()
            Button("Manage Spaces…") {
                SettingsNavigation.shared.currentSettingsTab = .spaces
                openSettings()
            }
            Divider()
            Button("Delete Space", role: .destructive) {
                actions?.confirmSpaceDeletion(
                    spaceName: space.name,
                    tabCount: tabs.tabCount(inSpace: space.id),
                    isLastSpace: tabs.orderedSpaces.count <= 1,
                    onDelete: { tabs.deleteSpace(space.id) }
                )
            }
            .disabled(tabs.orderedSpaces.count <= 1)
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .opacity(isRowHovered ? 1 : 0)
        .animation(HarborDesign.Motion.quick, value: isRowHovered)
    }

    private func isDropTarget(_ space: SpaceRecord) -> Bool {
        dragSession.isDragging && dragSession.activeZone == .target(.pinned(spaceID: space.id))
    }

    private func label(_ space: SpaceRecord) -> some View {
        let isDropTarget = isDropTarget(space)
        let title = HStack(spacing: HarborDesign.Spacing.xs) {
            if space.isAgent {
                Image(systemName: "sparkles").foregroundStyle(HarborDesign.Surface.agentGradient)
            }
            Text(space.name).foregroundStyle(.primary)
        }
            .font(HarborDesign.Font.label)
            .lineLimit(1)
            .fixedSize()
        // A name too long for the title row fades out, the way a tab row's title does.
        return ViewThatFits(in: .horizontal) {
            title
            title
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .harborTrailingFade()
        }
        .padding(.horizontal, HarborDesign.Spacing.sm)
        .frame(height: HarborDesign.Size.row)
        // Heading the tabs, the whole row takes the fill instead.
        .background(
            HarborDesign.Radius.shape(HarborDesign.Radius.md)
                .fill(!showsActions && (isHovering || isDropTarget) ? HarborDesign.Surface.fill : Color.clear)
        )
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onHoverTracking { isHovering = $0 }
    }

    /// Edits write straight through, so the window behind the popover follows the dots.
    private func themeBinding(_ space: SpaceRecord) -> Binding<SpaceTheme> {
        Binding {
            tabs.space(space.id)?.theme ?? .starting(from: space.accentHex)
        } set: { theme in
            tabs.updateSpace(space.id, name: nil, icon: nil, accentHex: theme.primaryHex, theme: theme)
        }
    }

    @ViewBuilder
    private func menuContent(current: SpaceRecord) -> some View {
        ForEach(tabs.orderedSpaces) { space in
            Button {
                tabs.setSpace(space.id, in: windowState)
            } label: {
                if space.id == current.id {
                    Label(space.name, systemImage: "checkmark")
                } else {
                    Text(space.name)
                }
            }
        }
        Divider()
        if !current.isAgent, !showsActions {
            Button("Edit Theme Color…", systemImage: "paintpalette") { showsThemeEditor = true }
        }
        Button("New Space…", systemImage: "plus", action: onNewSpace)
        Button("Space Settings", systemImage: "gearshape") {
            SettingsNavigation.shared.currentSettingsTab = .spaces
            openSettings()
        }
    }
}
