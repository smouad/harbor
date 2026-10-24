// Licensed under GPL-3.0. See LICENSE.
//
//  TabFolderView.swift
//  Harbor
//
//  Created by Jonathan Caudill on 2025-09-24.
//

import HarborTabsCore
import SwiftUI
import HarborDesign
import HarborWeb

/// A folder header row in the sidebar outline. Its children are separate rows below it.
public struct TabFolderView: View {
    let item: Item
    let spaceID: UUID
    /// True while a drag would drop into this folder.
    var isDropTarget: Bool = false

    @State private var isHovering: Bool = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    @Environment(BrowserWindowState.self) private var windowState
    private let renameState = SidebarRenameState.shared

    @Environment(TabsController.self) private var tabs
    private var isOpen: Bool { tabs.isOpen(folder: item.id) }
    private var isRenaming: Bool { renameState.itemID == item.id }

    public init(
        item: Item,
        spaceID: UUID,
        isDropTarget: Bool = false
    ) {
        self.item = item
        self.spaceID = spaceID
        self.isDropTarget = isDropTarget
    }

    public var body: some View {
        Button(action: {
            withAnimation(HarborDesign.Motion.spring) {
                tabs.toggleFolder(item.id)
            }
        }) {
            HStack(spacing: HarborDesign.Spacing.md) {
                Image(systemName: "chevron.right")
                    .font(.system(size: HarborDesign.Size.rowGlyph - 1, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .animation(HarborDesign.Motion.standard, value: isOpen)

                Image(systemName: liveSymbol ?? (isOpen ? "folder" : "folder.fill"))
                    .font(.system(size: HarborDesign.Size.spaceIcon, weight: .medium))
                    .foregroundStyle(tabs.space(spaceID)?.accentColor ?? .secondary)

                if isRenaming {
                    TextField("", text: $draftName)
                        .font(HarborDesign.Font.label)
                        .foregroundStyle(.primary)
                        .textFieldStyle(PlainTextFieldStyle())
                        .autocorrectionDisabled()
                        .focused($nameFieldFocused)
                        .onAppear {
                            draftName = item.displayTitle
                            DispatchQueue.main.async { nameFieldFocused = true }
                        }
                        .onSubmit { commitRename() }
                        .onEscapeKey { cancelRename() }
                } else {
                    Text(item.displayTitle)
                        .font(HarborDesign.Font.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: HarborDesign.Spacing.xs)

                if let status = tabs.liveStatus[item.id] {
                    Image(systemName: "exclamationmark.triangle")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .help(liveStatusHelp(status))
                }

                if !isHovering {
                    Text("\(tabs.children(of: .folder(itemID: item.id)).count)")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }

                if isHovering && !isRenaming {
                    // The same plain dots as the space's own menu.
                    Menu {
                        folderMenu
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: HarborDesign.Size.rowButton, height: HarborDesign.Size.rowButton)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.row)
            .frame(maxWidth: .infinity)
            .background(
                HarborDesign.Radius.shape(HarborDesign.Radius.md)
                    .fill(isDropTarget ? HarborDesign.Surface.fillPressed : (isHovering ? HarborDesign.Surface.fill : Color.clear))
            )
            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovering = hovering
            }
        }
        .contextMenu {
            folderMenu
                .environment(windowState)
                .environment(tabs)
        }
        .onChange(of: nameFieldFocused) { _, focused in
            if isRenaming && !focused { commitRename() }
        }
    }

    private var folderMenu: some View {
        FolderContextMenu(itemID: item.id, onRename: startRenaming)
    }

    // MARK: - Live

    private var liveSymbol: String? {
        switch item.live {
        case nil: return nil
        case .githubIssues?: return "smallcircle.filled.circle"
        case .githubNotifications?: return "bell"
        case .asanaTasks?: return "checkmark.circle"
        case let source?: return source.feedURL != nil ? "dot.radiowaves.up.forward" : "arrow.triangle.pull"
        }
    }

    private func liveStatusHelp(_ status: TabsController.LiveFolderStatus) -> String {
        let signedOut = status == .signedOut
        switch item.live {
        case .githubIssues?: return signedOut ? "Sign in to GitHub" : "Couldn't load issues"
        case .githubNotifications?: return signedOut ? "Sign in to GitHub" : "Couldn't load notifications"
        case .asanaTasks?: return signedOut ? "Sign in to Asana" : "Couldn't load tasks"
        case let source? where source.feedURL != nil: return "Couldn't load feed"
        default: return signedOut ? "Sign in to GitHub" : "Couldn't load pull requests"
        }
    }

    // MARK: - Rename

    private func startRenaming() {
        draftName = item.displayTitle
        renameState.itemID = item.id
    }

    private func cancelRename() {
        renameState.itemID = nil
        nameFieldFocused = false
    }

    private func commitRename() {
        guard isRenaming else { return }
        let newName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty && newName != item.displayTitle {
            tabs.rename(item.id, newName)
        }
        cancelRename()
    }
}
