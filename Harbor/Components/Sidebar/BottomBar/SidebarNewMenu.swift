// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarNewMenu.swift
//  Harbor
//
//  The card the bottom bar's plus opens, drawn as Arc draws it: a dark rounded card above the
//  button with an icon, a name and the shortcut on each row.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

struct SidebarNewMenu: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    let onNewSpace: () -> Void
    let dismiss: () -> Void

    @State private var highlighted = "New Tab"

    private let width: CGFloat = 220
    private let iconWidth: CGFloat = 20

    /// The row Return would take is filled with the space's color, and the fill follows the pointer.
    private var accent: Color { browserManager.gradientColorManager.accentColor }

    var body: some View {
        VStack(spacing: HarborDesign.Spacing.xxs) {
            row("New Space", "plus.square.on.square") { onNewSpace() }
            row("New Folder", "folder.badge.plus") {
                if let spaceID = windowState.spaceID {
                    tabs.createFolderForRename(in: .tabs(spaceID: spaceID), after: nil)
                }
            }
            if !windowState.isIncognito {
                liveFolders
            }
            divider
            row("New Tab", "plus.square", shortcut: shortcut(.newTab)) {
                windowState.commandPalette?.open()
            }
        }
        .padding(HarborDesign.Spacing.sm)
        .frame(width: width)
        .background(Color(white: 0.11))
        // The card is dark whatever the window is, as in Arc.
        .environment(\.colorScheme, .dark)
    }

    private var divider: some View {
        Divider().padding(.vertical, HarborDesign.Spacing.xs).padding(.horizontal, HarborDesign.Spacing.sm)
    }

    /// One row that opens the live folder sources, so the card stays short.
    private var liveFolders: some View {
        Menu {
            ForEach(LiveFolderMenuItem.all, id: \.title) { entry in
                Button(entry.title, systemImage: entry.symbol) {
                    if let spaceID = windowState.spaceID {
                        tabs.createLiveFolder(entry.source, in: spaceID)
                    }
                    dismiss()
                }
            }
            Button("New Feed Folder…", systemImage: "dot.radiowaves.up.forward") {
                if let spaceID = windowState.spaceID {
                    browserManager.presentFeedFolderPrompt(in: spaceID)
                }
                dismiss()
            }
        } label: {
            NewMenuRow(title: "Live Folders", symbol: "bolt.horizontal", shortcut: nil, iconWidth: iconWidth, hasSubmenu: true,
                       isSelected: highlighted == "Live Folders", accent: accent) { highlighted = "Live Folders" }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private func row(_ title: String, _ symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            dismiss()
            action()
        } label: {
            NewMenuRow(title: title, symbol: symbol, shortcut: shortcut, iconWidth: iconWidth, hasSubmenu: false,
                       isSelected: highlighted == title, accent: accent) { highlighted = title }
        }
        .buttonStyle(.plain)
    }

    /// The shortcut as Arc prints it, glyphs run together.
    private func shortcut(_ action: ShortcutAction) -> String? {
        guard let combination = browserManager.keyboardShortcutManager?.shortcut(for: action)?.keyCombination else { return nil }
        return (combination.modifiers.displayStrings + [combination.key.uppercased()]).joined()
    }
}

private struct NewMenuRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let iconWidth: CGFloat
    let hasSubmenu: Bool
    let isSelected: Bool
    let accent: Color
    let onHover: () -> Void

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            Image(systemName: symbol)
                .frame(width: iconWidth)
                .foregroundStyle(isSelected ? .white : .secondary)
            Text(title).foregroundStyle(isSelected ? .white : .primary)
            Spacer(minLength: HarborDesign.Spacing.md)
            if let shortcut {
                Text(shortcut).foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            } else if hasSubmenu {
                Image(systemName: "chevron.right").foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
            }
        }
        .font(HarborDesign.Font.label)
        .padding(.horizontal, HarborDesign.Spacing.md)
        .frame(height: HarborDesign.Size.row)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.md)
            .fill(isSelected ? accent : .clear))
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onHover { if $0 { onHover() } }
    }
}
