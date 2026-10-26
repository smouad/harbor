// Licensed under GPL-3.0. See LICENSE.
//
//  SpacesSideBarView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//  Refactored by Aether on 15/11/2025.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Sparkle
import HarborDesign
import HarborSettings
import HarborTabsCore
import HarborWeb
import HarborUI

struct SpacesSideBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(\.harborSettings) var harborSettings
    @Environment(CommandPalette.self) var commandPalette
    @Environment(TabOrganizerManager.self) var tabOrganizerManager

    // Space navigation. Keyed by space id: an index outlives the space it pointed at.
    @State private var activeSpaceID: UUID?

    // Hover states
    @State private var isSidebarHovered: Bool = false
    @State private var isMenuButtonHovered = false
    @State private var isDownloadsHovered = false
    @State private var showDownloadsMenu = false
    @State private var animateDownloadsMenu: Bool = false

    var body: some View {
        sidebarContent
            .contentShape(Rectangle())
            .onHoverTracking { state in
                isSidebarHovered = state
            }
            .contextMenu {
                sidebarContextMenu
            }
    }

    // MARK: - Main Content

    private var sidebarContent: some View {
        ZStack {
            if windowState.isSidebarMenuVisible {
                SidebarMenu()
                    .transition(menuTransition)
            } else {
                mainSidebarContent
                    .transition(.opacity)
            }
        }
    }

    @ObservedObject private var dragSession = HarborDragSessionManager.shared

    private var mainSidebarContent: some View {
        return VStack(spacing: HarborDesign.Spacing.sectionGap) {
            // History buttons: share the traffic-light row on the left, their own row on the right.
            if harborSettings.sidebarPosition != .left && !harborSettings.topBarAddressView {
                titleRow
                    .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
            }

            // Header (window controls, nav buttons, URL bar)
            SidebarHeader(isSidebarHovered: isSidebarHovered, onNewSpace: showSpaceCreationDialog)
                .environmentObject(browserManager)
                .environment(windowState)

            // Spaces page view with draggable spacer
            ZStack {
                spacesPageView
                    .zIndex(1)

                // Bottom spacer for window dragging
                Color.clear
                    .contentShape(Rectangle())
                    .conditionalWindowDrag()
                    .frame(minHeight: HarborDesign.Size.bottomBar)
                    .zIndex(0)
            }

            // Downloads menu hover overlay
            if showDownloadsMenu, !browserManager.downloadManager.recentDownloads.isEmpty {
                downloadsMenuOverlay
            }

            // Update notification
            SidebarUpdateNotification(downloadsMenuVisible: showDownloadsMenu)
                .environmentObject(browserManager)
                .environment(windowState)
                .environment(harborSettings)
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
                .padding(.bottom, HarborDesign.Spacing.sidebarInset)

            SidebarWhatsNewCard()
                .environmentObject(browserManager)
                .environment(windowState)
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
                .padding(.bottom, HarborDesign.Spacing.sidebarInset)

            // Video left playing in another tab, directly above the media controls
            SidebarPiPView()
                .environmentObject(browserManager)
                .environment(windowState)

            if !windowState.isIncognito, let agent = tabs.agentSpaceID, windowState.spaceID != agent,
               !tabs.displayOrder(inSpace: agent).isEmpty {
                AgentSpaceRow(tabCount: tabs.displayOrder(inSpace: agent).count, busy: tabs.agentCallsInFlight > 0) {
                    withAnimation(HarborDesign.Motion.standard) { tabs.setSpace(agent, in: windowState) }
                }
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
            }

            // Media controls. Hides itself while the video is showing above it.
            MediaControlsView()
                .environmentObject(browserManager)
                .environment(windowState)

            // Bottom bar (menu, spaces indicators, new space)
            SidebarBottomBar(
                isMenuButtonHovered: $isMenuButtonHovered,
                onMenuTap: handleMenuTap,
                onNewSpaceTap: showSpaceCreationDialog,
                onMenuHover: handleMenuHover
            )
            .environmentObject(browserManager)
            .environment(windowState)
        }
        // Extra top padding when sidebar is on the left to avoid overlapping native traffic light buttons
        .padding(.top, harborSettings.sidebarPosition == .left ? HarborDesign.Spacing.sidebarTop : HarborDesign.Spacing.sidebarInset)
        .overlay(alignment: .topLeading) {
            if harborSettings.sidebarPosition == .left {
                titleRow
                    .frame(height: HarborDesign.Spacing.sidebarTop)
                    .padding(.leading, HarborDesign.Spacing.trafficLights)
                    .padding(.trailing, HarborDesign.Spacing.sidebarInset)
            }
        }
        .padding(.bottom, HarborDesign.Spacing.sidebarInset)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        updateSidebarScreenFrame(geo)
                    }
                    .onChange(of: geo.frame(in: .global)) { _, _ in
                        updateSidebarScreenFrame(geo)
                    }
            }
        )
    }

    private func updateSidebarScreenFrame(_ geo: GeometryProxy) {
        let frame = geo.frame(in: .global)
        guard let window = windowState.window ?? NSApp.windows.first(where: { $0.isVisible }),
              let contentView = window.contentView else { return }
        let appKitY = contentView.bounds.height - frame.maxY
        let bottomLeft = NSPoint(x: frame.origin.x, y: appKitY)
        let screenBottomLeft = window.convertPoint(toScreen: bottomLeft)
        dragSession.sidebarScreenFrame = CGRect(
            x: screenBottomLeft.x,
            y: screenBottomLeft.y,
            width: frame.width,
            height: frame.height
        )
    }

    // MARK: - Spaces Page View

    private var spacesPageView: some View {
        let spaces = tabs.switchableSpaces(for: windowState)

        return Group {
            if spaces.isEmpty {
                emptyStateView
            } else {
                spacesContent(spaces: spaces)
            }
        }
    }

    private func spacesContent(spaces: [SpaceRecord]) -> some View {
        // A deleted (or private-window) space falls back to the first one still here.
        let selection = Binding<UUID> {
            spaces.first { $0.id == activeSpaceID }?.id ?? spaces[0].id
        } set: { activeSpaceID = $0 }

        return PageView(selection: selection) {
            ForEach(spaces) { space in
                makeSpaceView(for: space)
            }
        }
        .pageViewStyle(.scroll)
        .contentShape(Rectangle())
        // Pages are cached hosting views; a different set of spaces needs new pages.
        .id(spaces.map(\.id.uuidString).joined(separator: ","))
        .onAppear {
            activeSpaceID = windowState.spaceID
            if !spaces.contains(where: { $0.id == windowState.spaceID }) {
                tabs.setSpace(spaces[0].id, in: windowState)
            }
        }
        .onChange(of: activeSpaceID) { _, newID in
            handleSpaceSelectionChange(newID, spaces: spaces)
        }
        .onChange(of: windowState.spaceID) { _, newID in
            // A swipe already shows this space. A dot, a shortcut or the menu shows its page at
            // once, without an animation: rebuilding every page here made each of those switches
            // wait on a full redraw, and a programmatic slide that never finished (a window in
            // the background) left the last space's page on screen.
            guard activeSpaceID != newID else { return }
            withTransaction(Transaction(animation: nil)) { activeSpaceID = newID }
        }
    }


    private var emptyStateView: some View {
        VStack(spacing: HarborDesign.Spacing.xl) {
            Image(systemName: "square.grid.2x2")
                .font(HarborDesign.Font.hero)
                .foregroundColor(.secondary)
            VStack(spacing: HarborDesign.Spacing.md) {
                Text("No Spaces")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Create a space to start browsing")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            Button(action: showSpaceCreationDialog) {
                Label("Create Space", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Downloads Menu

    private var downloadsMenuOverlay: some View {
        SidebarMenuHoverDownloads(isVisible: animateDownloadsMenu)
            .onHoverTracking { isHovered in
                isDownloadsHovered = isHovered
                if isHovered {
                    showDownloadsMenu = true
                    animateDownloadsMenu = true
                } else {
                    hideMenuAfterDelay()
                }
            }
    }

    // MARK: - Context Menu

    private var sidebarContextMenu: some View {
        Group {
            Button {
                commandPalette.open()
            } label: {
                Label("New Tab", systemImage: "plus")
            }

            Button {
                if let spaceID = windowState.spaceID {
                    tabs.createFolderForRename(in: .tabs(spaceID: spaceID), after: nil)
                }
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }

            if !windowState.isIncognito {
                ForEach(LiveFolderMenuItem.all, id: \.title) { entry in
                    Button {
                        if let spaceID = windowState.spaceID {
                            tabs.createLiveFolder(entry.source, in: spaceID)
                        }
                    } label: {
                        Label(entry.title, systemImage: entry.symbol)
                    }
                }
                Button {
                    if let spaceID = windowState.spaceID {
                        browserManager.presentFeedFolderPrompt(in: spaceID)
                    }
                } label: {
                    Label("New Feed Folder…", systemImage: "dot.radiowaves.up.forward")
                }
            }

            Divider()

            Menu {
                ForEach(SidebarPosition.allCases) { position in
                    Toggle(isOn: Binding(
                        get: { harborSettings.sidebarPosition == position },
                        set: { _ in harborSettings.sidebarPosition = position }
                    )) {
                        Label(position.displayName, systemImage: position.icon)
                    }
                }
            } label: {
                Label("Position", systemImage: harborSettings.sidebarPosition.icon)
            }
        }
    }

    // MARK: - Helper Functions

    private func handleMenuTap() {
        withAnimation(HarborDesign.Motion.standard) {
            windowState.isSidebarMenuVisible = true
            windowState.isSidebarAIChatVisible = false
            let previousWidth = windowState.sidebarWidth
            windowState.savedSidebarWidth = previousWidth
            let newWidth: CGFloat = 400
            windowState.sidebarWidth = newWidth
            windowState.sidebarContentWidth = max(newWidth - 16, 0)
        }
    }

    private func handleMenuHover(_ isHovered: Bool) {
        if isHovered {
            showDownloadsMenu = true
            animateDownloadsMenu = true
        } else {
            hideMenuAfterDelay()
        }
    }

    private func hideMenuAfterDelay() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if !isMenuButtonHovered, !isDownloadsHovered {
                animateDownloadsMenu = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    showDownloadsMenu = false
                }
            }
        }
    }

    private func handleSpaceSelectionChange(_ newID: UUID?, spaces: [SpaceRecord]) {
        guard let newID, newID != windowState.spaceID, spaces.contains(where: { $0.id == newID }) else { return }
        // Haptic fires during swipe at 15% offset in PlatformPageView
        tabs.setSpace(newID, in: windowState)
    }

    @ViewBuilder
    private func makeSpaceView(for space: SpaceRecord) -> some View {
        SpacePageFrame {
            spacePage(for: space)
        }
        .environment(windowState)
        .environment(tabs)
    }

    @ViewBuilder
    private func spacePage(for space: SpaceRecord) -> some View {
        VStack(spacing: 0) {
            if !windowState.isIncognito {
                PinnedGrid(spaceID: space.id)
                .environmentObject(browserManager)
                .environment(tabs)
                .environment(windowState)
                .environment(windowRegistry)
                .environment(harborSettings)
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
                .padding(.bottom, HarborDesign.Spacing.sectionGap)
            }

            // The space's name heads its own tabs, under the favorites, as Arc places it. It stays
            // here whichever side the address bar is on: moving the address bar only moves the bar.
            SpaceSwitcherTitle(spaceID: space.id, onNewSpace: showSpaceCreationDialog, showsActions: true)
                .environmentObject(browserManager)
                .environment(tabs)
                .environment(windowState)
                .environment(harborSettings)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
                .padding(.bottom, HarborDesign.Spacing.xs)

            SpaceView(
                spaceID: space.id,
                isActive: windowState.spaceID == space.id,
                isSidebarHovered: $isSidebarHovered
            )
            // Pages are separate hosting views and inherit nothing; a split row needs `tabs`.
            .environmentObject(browserManager)
            .environment(tabs)
            .environment(\.tabActions, browserManager)
            .environment(windowState)
            .environment(windowRegistry)
            .environment(commandPalette)
            .environment(tabOrganizerManager)
            .environment(harborSettings)
            .environmentObject(browserManager.gradientColorManager)
            .environmentObject(browserManager.splitManager)
            Spacer()
        }
        // `.environment(harborSettings)` above sets the object by type; views read the key.
        .environment(\.harborSettings, harborSettings)
    }

    /// Back, forward and reload at the trailing edge. With the address in the top bar those live
    /// there, and on the left the sidebar controls and space name take this row instead.
    private var titleRow: some View {
        HStack(spacing: 0) {
            if !harborSettings.topBarAddressView {
                // The address lives in the sidebar: the window's controls share the lights' row.
                if harborSettings.sidebarPosition == .left {
                    Button("Toggle Sidebar", systemImage: "sidebar.left") {
                        browserManager.toggleSidebar(for: windowState)
                    }
                    .buttonStyle(HarborCircleButtonStyle())
                }
                Spacer(minLength: 0)
                SidebarHistoryButtons()
                    .environmentObject(browserManager)
                    .environment(windowState)
            }
        }
    }

    // MARK: - Dialogs

    private func showSpaceCreationDialog() {
        browserManager.dialogManager.showDialog(
            SpaceCreationDialog(
                onCreate: { name, accentHex in
                    if let spaceID = tabs.createSpace(
                        name: name.isEmpty ? "New Space" : name,
                        icon: "square.grid.2x2",
                        accentHex: accentHex,
                        after: tabs.orderedSpaces.last?.id
                    ) {
                        tabs.setSpace(spaceID, in: windowState)
                    }
                    browserManager.dialogManager.closeDialog()
                },
                onCancel: {
                    browserManager.dialogManager.closeDialog()
                }
            )
        )
    }


    // MARK: - Computed Properties

    private var menuTransition: AnyTransition {
        .move(edge: harborSettings.sidebarPosition == .left ? .leading : .trailing)
            .combined(with: .opacity)
    }
}

/// The Agent space while the window shows another: a click opens it, and the icon pulses while a
/// tool call runs, in an active window only. Each pulse frame waits for the window server to show
/// the last one, and a window covered by another app is never shown: the pulse then held the main
/// thread, and with it the agent's own call, which kept the pulse going.
private struct AgentSpaceRow: View {
    let tabCount: Int
    let busy: Bool
    let toggle: () -> Void
    @State private var isHovering = false
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: HarborDesign.Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.system(size: HarborDesign.Size.rowGlyph, weight: .medium))
                    .foregroundStyle(HarborDesign.Surface.agentGradient)
                    .frame(width: HarborDesign.Size.favicon)
                    .symbolEffect(.pulse, isActive: busy && activeState != .inactive)
                Text("Agent · \(tabCount) \(tabCount == 1 ? "tab" : "tabs")")
                    .font(HarborDesign.Font.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? .secondary : .tertiary)
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.row)
            .background(isHovering ? HarborDesign.Surface.fill : Color.clear)
            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
        .buttonStyle(.plain)
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) { isHovering = hovering }
        }
    }
}

/// A space's page, held to the sidebar's width. Pages are cached hosting views that do not always
/// follow the sidebar when it is resized or the window changes, and a page left wider than the
/// sidebar pushed its rows and favorites past the edge. The width is read here, in the page's own
/// body, so it is current whatever the parent last passed.
private struct SpacePageFrame<Content: View>: View {
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(TabsController.self) private var tabs
    @ViewBuilder var content: Content
    /// Shared by every selectable row and tile on the page: the highlight is one shape that
    /// moves between them (`rowSelectionHighlight`).
    @Namespace private var selection

    var body: some View {
        content
            .environment(\.rowSelectionNamespace, selection)
            // A change of selection carries the highlight across with a spring.
            .animation(HarborDesign.Motion.spring, value: tabs.selectedItemID(in: windowState))
            .frame(width: windowState.sidebarWidth > 0 ? windowState.sidebarWidth : nil, alignment: .topLeading)
            .clipped()
    }
}
