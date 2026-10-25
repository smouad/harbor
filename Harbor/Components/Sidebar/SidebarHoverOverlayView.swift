// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarHoverOverlayView.swift
//  Harbor
//
//  Created by Jonathan Caudill on 2025-09-13.
//

import SwiftUI
import AppKit
import HarborDesign
import HarborWeb
import HarborUI

struct SidebarHoverOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @EnvironmentObject var hoverManager: HoverSidebarManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.harborSettings) var harborSettings

    private let cornerRadius: CGFloat = HarborDesign.Radius.lg
    private let horizontalInset: CGFloat = HarborDesign.Spacing.md
    private let verticalInset: CGFloat = HarborDesign.Spacing.md

    var body: some View {
        // Only render overlay plumbing when the real sidebar is collapsed
        if !windowState.isSidebarVisible {
            ZStack(alignment: harborSettings.sidebarPosition == .left ? .leading : .trailing) {
                // Edge hover hotspot
                Color.clear
                    .frame(width: hoverManager.triggerWidth)
                    .contentShape(Rectangle())
                    .onHoverTracking { isIn in
                        if isIn && !windowState.isSidebarVisible {
                            withAnimation(HarborDesign.Motion.quick) {
                                hoverManager.isOverlayVisible = true
                            }
                        }
                        NSCursor.arrow.set()
                    }

                if hoverManager.isOverlayVisible {
                    SpacesSideBarView()
                        .frame(width: windowState.sidebarWidth)
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .environment(commandPalette)
                        .environmentObject(browserManager.gradientColorManager)
                        .frame(maxHeight: .infinity)
                        .background(sidebarBackground)
                        .harborFloatingSurface(in: HarborDesign.Radius.shape(cornerRadius))
                        .alwaysArrowCursor()
                        .padding(harborSettings.sidebarPosition == .left ? .leading : .trailing, horizontalInset)
                        .padding(.vertical, verticalInset)
                        .transition(
                            .move(edge: harborSettings.sidebarPosition == .left ? .leading : .trailing)
                                .combined(with: .opacity)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: harborSettings.sidebarPosition == .left ? .topLeading : .topTrailing)
            // Container remains passive; only overlay/hotspot intercept
        }
    }

    /// The docked sidebar's own background, so the overlay reads as the same sidebar.
    private var sidebarBackground: some View {
        let accent = browserManager.accentColor(for: windowState)
        let isAgent = windowState.spaceID != nil && windowState.spaceID == browserManager.tabs.agentSpaceID
        let theme = windowState.isIncognito || isAgent ? nil : windowState.spaceID.flatMap { browserManager.tabs.space($0)?.theme }
        return Group {
            if let theme {
                SpaceThemeBackground(theme: theme, isActive: true)
            } else {
                HarborDesign.Surface.containerGradient(accent: accent, isActive: true)
            }
        }
            .overlay(windowState.isIncognito ? HarborDesign.Surface.privateTint : Color.clear)
            .overlay(Rectangle().fill(HarborDesign.Surface.agentGradient).opacity(isAgent ? HarborDesign.Surface.agentChromeOpacity : 0))
            .overlay { if theme == nil { HarborGrain() } }
    }
}
