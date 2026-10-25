// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHeader.swift
//  Harbor
//
//  Created by Aether on 15/11/2025.
//

import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

/// Header section of the sidebar (window controls and space name, URL bar). Back, forward and
/// reload sit in the title row above it.
struct SidebarHeader: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.harborSettings) var harborSettings
    let isSidebarHovered: Bool
    let onNewSpace: () -> Void

    var body: some View {
        VStack(spacing: HarborDesign.Spacing.sectionGap) {
            if showsControlsRow {
                windowControls
            }

            if !harborSettings.topBarAddressView {
                urlBar
            }
        }
    }

    /// The space's name always heads its tabs (`SpaceView`'s title), so this row is only buttons.
    private var showsControlsRow: Bool {
        harborSettings.sidebarPosition != .left
    }

    private var windowControls: some View {
        SidebarWindowControlsView(showsTitle: false, onNewSpace: onNewSpace)
            .environmentObject(browserManager)
            .environment(windowState)
            .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
    }

    private var urlBar: some View {
        URLBarView(isSidebarHovered: isSidebarHovered)
            .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
    }
}

// MARK: - Sidebar Window Controls
/// The sidebar and AI toggles, with the space name at the trailing edge.
struct SidebarWindowControlsView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.harborSettings) var harborSettings
    var showsTitle: Bool = true
    let onNewSpace: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            // The name leads the row, as a section title does; it gives way before the buttons,
            // so a long name fades out.
            if showsTitle {
                SpaceSwitcherTitle(onNewSpace: onNewSpace)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: HarborDesign.Spacing.xxs) {
                // On the left the traffic-light row already has it.
                if harborSettings.sidebarPosition != .left {
                    Button("Toggle Sidebar", systemImage: "sidebar.right") {
                        browserManager.toggleSidebar(for: windowState)
                    }
                }
            }
            .harborIconButtons()
        }
        .frame(height: HarborDesign.Size.chromeControl)
    }
}
