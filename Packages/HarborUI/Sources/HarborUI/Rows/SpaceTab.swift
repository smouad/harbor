// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceTab.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb

/// One tab row in the sidebar outline.
public struct SpaceTab: View {
    let item: Item
    var menuContext: TabMenuContext = .sidebar
    /// A tab with a trail of child tabs draws a chevron that collapses it, as a folder row does.
    var hasChildren = false

    @State private var isHovering: Bool = false
    @State private var isCloseHovering: Bool = false
    @State private var isResetHovering: Bool = false
    @State private var draftName: String = ""
    @FocusState private var isTextFieldFocused: Bool
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.tabActions) private var actions
    private let renameState = SidebarRenameState.shared

    @Environment(TabsController.self) private var tabs
    private var session: PageSession? { tabs.session(for: item.id) }
    private var isRenaming: Bool { renameState.itemID == item.id }
    private var isUnloaded: Bool { session?.isUnloaded ?? true }


    public init(
        item: Item,
        menuContext: TabMenuContext = .sidebar,
        hasChildren: Bool = false
    ) {
        self.item = item
        self.menuContext = menuContext
        self.hasChildren = hasChildren
    }

    /// The folder row's chevron; clicking it collapses the trail without selecting the tab.
    private var trailChevron: some View {
        let isOpen = tabs.isOpen(folder: item.id)
        return Button(action: {
            withAnimation(HarborDesign.Motion.spring) { tabs.toggleFolder(item.id) }
        }) {
            Image(systemName: "chevron.right")
                .font(.system(size: HarborDesign.Size.rowGlyph - 1, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .animation(HarborDesign.Motion.standard, value: isOpen)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    public var body: some View {
        let title = tabs.title(for: item)
        Button(action: {
            if isCurrentTab {
                startRename(title)
            } else {
                if isRenaming { commitRename() }
                tabs.select(item.id, in: windowState)
            }
        }) {
            HStack(spacing: HarborDesign.Spacing.md) {
                if hasChildren { trailChevron }
                ItemFavicon(item: item, session: session)
                    .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
                    .overlay(alignment: .bottomTrailing) {
                        // The tab DevMCP page tools act on.
                        if tabs.agentItemID == item.id {
                            Image(systemName: "sparkle")
                                .font(HarborDesign.Font.micro)
                                .foregroundStyle(.primary)
                                .padding(HarborDesign.Spacing.xxs / 2)
                                .background(.background, in: Circle())
                                .offset(x: HarborDesign.Spacing.xs, y: HarborDesign.Spacing.xs)
                        }
                    }
                if let session, session.hasAudioContent || session.hasPlayingAudio || session.isAudioMuted {
                    Button(action: { session.toggleMute() }) {
                        Image(systemName: session.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .contentTransition(.symbolEffect(.replace))
                            .font(.system(size: HarborDesign.Size.rowGlyph, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(session.isAudioMuted ? "Unmute" : "Mute")
                }

                if isRenaming {
                    TextField("", text: $draftName)
                        .font(HarborDesign.Font.body)
                        .foregroundStyle(isUnloaded ? .secondary : .primary)
                        .textFieldStyle(.plain)
                        .onSubmit { commitRename() }
                        .onEscapeKey { renameState.itemID = nil }
                        .focused($isTextFieldFocused)
                        .onAppear {
                            if draftName.isEmpty { draftName = title }
                            isTextFieldFocused = true
                        }
                } else {
                    // Hidden shrinkable copy sizes the row; the visible copy is laid out at
                    // full width and faded, so long titles never widen the row.
                    Text(title)
                        .font(HarborDesign.Font.body)
                        .lineLimit(1)
                        .hidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Text(title)
                                .font(HarborDesign.Font.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .id(title)
                                .transition(.blurReplace)
                        }
                        // Only a rename animates; a page changing its own title swaps without motion.
                        .animation(HarborDesign.Motion.spring, value: item.customTitle)
                        // On hover the text ends before the close button.
                        .harborTrailingFade(reserving: isHovering ? HarborDesign.Size.row + (showsReset ? HarborDesign.Size.rowButton : 0) : 0)
                        .textSelection(.disabled)
                }
            }
            .overlay(alignment: .trailing) {
                if isHovering {
                    HStack(spacing: 0) {
                        // Resets a pinned tab whose page left its pinned URL; sits left of close and fades in with it.
                        if showsReset {
                            Button { tabs.resetToHome(item.id) } label: {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(HarborDesign.Font.secondary)
                                    .foregroundStyle(.primary)
                                    .frame(width: HarborDesign.Size.rowButton, height: HarborDesign.Size.rowButton)
                                    .background(isResetHovering ? HarborDesign.Surface.fillPressed : Color.clear)
                                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
                            }
                            .buttonStyle(.plain)
                            .help("Reset to Pinned URL")
                            .onHoverTracking { isResetHovering = $0 }
                        }
                        // Synced loaded tabs: "-" unloads the page; unloaded synced tabs: "x" removes the item;
                        // tabs section: "x" closes.
                        let useUnload = tabs.isSynced(item.id) && !isUnloaded
                        Button(action: {
                            if useUnload { tabs.unload(item.id) } else { tabs.remove(item.id) }
                        }) {
                            Image(systemName: useUnload ? "minus" : "xmark")
                                .font(HarborDesign.Font.secondary)
                                .foregroundColor(.primary)
                                .frame(width: HarborDesign.Size.rowButton, height: HarborDesign.Size.rowButton)
                                .background(isCloseHovering ? HarborDesign.Surface.fillPressed : Color.clear)
                                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(useUnload ? "Unload" : "Close")
                        .onHoverTracking { hovering in
                            isCloseHovering = hovering
                        }
                    }
                }
            }
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.row)
            .frame(minWidth: 0, maxWidth: .infinity)
            .background(backgroundColor)
            .overlay {
                if isRenaming {
                    HarborDesign.Radius.shape(HarborDesign.Radius.md)
                        .strokeBorder(accentColor, lineWidth: HarborDesign.Size.hairlineWidth)
                }
            }
            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
            .harborRowSelection(isCurrentTab)
            .opacity(isUnloaded ? HarborDesign.Surface.unloadedOpacity : 1)
        }
        .buttonStyle(PlainButtonStyle())
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovering = hovering
            }
            // Read by the middle-click handler in AppDelegate. Only clear the slot if
            // it still points at this row, so the enter of the next row wins the race
            // against the exit of this one.
            if hovering {
                windowState.hoveredItemID = item.id
            } else if windowState.hoveredItemID == item.id {
                windowState.hoveredItemID = nil
            }
        }
        .onChange(of: isTextFieldFocused) { _, focused in
            if isRenaming && !focused { commitRename() }
        }
        .onChange(of: isRenaming) { _, renaming in
            if renaming { draftName = title }
        }
        .contextMenu {
            TabContextMenu(itemID: item.id, context: menuContext)
                .environment(windowState)
                .environment(tabs)
                .environment(\.tabActions, actions)
        }
        .harborElevation(isCurrentTab ? .raised : .flat)
    }

    private var accentColor: Color { actions?.accentColor ?? .accentColor }

    private var isCurrentTab: Bool {
        tabs.selectedItemID(in: windowState) == item.id
    }

    private var showsReset: Bool { tabs.hasLeftHome(item.id) }

    private var backgroundColor: Color {
        if isCurrentTab {
            return Color.clear
        } else if isHovering {
            return HarborDesign.Surface.fill
        } else {
            return Color.clear
        }
    }

    private func startRename(_ title: String) {
        draftName = title
        renameState.itemID = item.id
        isTextFieldFocused = true
    }

    /// Empty input clears the custom title.
    private func commitRename() {
        guard isRenaming else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        renameState.itemID = nil
        isTextFieldFocused = false
        if name != tabs.title(for: item) || name.isEmpty {
            tabs.rename(item.id, name.isEmpty ? nil : name)
        }
    }
}
