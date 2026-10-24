// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarBottomBar.swift
//  Harbor
//
//  Created by Aether on 15/11/2025.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

/// Bottom bar of the sidebar containing menu button, spaces list, and new space button
struct SidebarBottomBar: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Binding var isMenuButtonHovered: Bool
    let onMenuTap: () -> Void
    let onNewSpaceTap: () -> Void
    let onMenuHover: (Bool) -> Void
    @State private var showsNewMenu = false
    
    var body: some View {
        HStack(alignment: .center, spacing: HarborDesign.Spacing.xxs) {
            menuButton

            // Hide spaces list in incognito windows (only one ephemeral space)
            if !windowState.isIncognito {
                SpacesList()
                    .frame(maxWidth: .infinity)
                    .environmentObject(browserManager)
                    .environment(windowState)
            }

            // Hide new space button in incognito windows
            if !windowState.isIncognito {
                newSpaceButton
            }
        }
        .frame(height: HarborDesign.Size.bottomBar)
        .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
    }
    
    private var menuButton: some View {
        ZStack {
            Button("Menu", systemImage: "archivebox") {
                onMenuTap()
            }
            // A finished download bounces the button its icon flew into.
            .symbolEffect(.bounce, value: browserManager.downloadManager.completedCount)
            .harborIconButtons()
            .anchorPreference(key: DownloadsButtonAnchorKey.self, value: .bounds) { $0 }
            .onHoverTracking { isHovered in
                isMenuButtonHovered = isHovered
                onMenuHover(isHovered)
            }
            
            DownloadIndicator()
                .offset(x: HarborDesign.Spacing.lg, y: -HarborDesign.Spacing.lg)
        }
    }
    
    private var newSpaceButton: some View {
        Button {
            showsNewMenu.toggle()
        } label: {
            // The plus turns into a cross while its card is open, as in Arc.
            Label("Actions", systemImage: showsNewMenu ? "xmark" : "plus")
                .contentTransition(.symbolEffect(.replace))
        }
        .harborIconButtons()
        .popover(isPresented: $showsNewMenu, arrowEdge: .top) {
            SidebarNewMenu(onNewSpace: onNewSpaceTap) { showsNewMenu = false }
                .environmentObject(browserManager)
                .environment(tabs)
                .environment(windowState)
        }
    }
}

/// The live folder sources the sidebar's create menus offer, besides feeds.
struct LiveFolderMenuItem {
    let title: String
    let symbol: String
    let source: LiveSource

    static let all = [
        LiveFolderMenuItem(title: "New Pull Requests Folder", symbol: "arrow.triangle.pull", source: .githubPulls),
        LiveFolderMenuItem(title: "New Issues Folder", symbol: "smallcircle.filled.circle", source: .githubIssues),
        LiveFolderMenuItem(title: "New Notifications Folder", symbol: "bell", source: .githubNotifications),
        LiveFolderMenuItem(title: "New Asana Tasks Folder", symbol: "checkmark.circle", source: .asanaTasks),
    ]
}
