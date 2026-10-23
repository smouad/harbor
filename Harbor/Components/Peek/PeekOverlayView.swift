// Licensed under GPL-3.0. See LICENSE.
//
//  PeekOverlayView.swift
//  Harbor
//
//  Created by Jonathan Caudill on 24/09/2025.
//

import HarborTabsCore
import SwiftUI
import HarborDesign
import HarborWeb
import AppKit
import HarborUI

struct PeekOverlayView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) var windowState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.harborSettings) var harborSettings

    private var peek: PeekManager { browserManager.peekManager }

    /// Peek belongs to the window that opened it; the others show nothing.
    private var page: PageSession? {
        peek.windowId == windowState.id ? peek.page : nil
    }

    private var currentSpaceColor: Color {
        windowState.spaceID.flatMap { tabs.space($0)?.accentColor } ?? Color.accentColor
    }

    var body: some View {
        ZStack {
            if let page {
                backgroundOverlay
                    .transition(.opacity)
                peekContent(page: page)
                    .transition(.scale(scale: 0.001).combined(with: .opacity))
                    .zIndex(1000)
            }
        }
        .zIndex(9999) // Put it at the very top
        .animation(HarborDesign.Motion.spring, value: page?.itemID)
    }

    private var backgroundOverlay: some View {
        Color.black.opacity(0.3)
            .contentShape(Rectangle()) // Ensure proper hit testing
            .onTapGesture { peek.dismissPeek() }
    }

    private func peekContent(page: PageSession) -> some View {
        GeometryReader { geometry in
            let (frame, cornerRadius) = calculateLayout(geometry: geometry)

            ZStack {
                // The card's surface and shadow sit behind the page, never on it: see DetachedPageHost.
                HarborDesign.Radius.shape(cornerRadius)
                    .fill(colorScheme == .dark ? Color.black : Color.white)
                    .harborElevation(.floating)

                DetachedPageHost(page: page, cornerRadius: cornerRadius)
                    .id(page.itemID)

                BlockedPageView(session: page)

                if let webView = page.webView {
                    PageLoadBar(webView: webView, tint: currentSpaceColor)
                        .padding(.horizontal, cornerRadius)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .id(page.itemID)
                }
            }
            .frame(width: frame.width, height: frame.height)
            // The buttons sit in the margin left of the card, level with its top.
            .overlay(alignment: .topLeading) {
                actionButtons
                    .alignmentGuide(.leading) { $0[.trailing] + HarborDesign.Spacing.lg }
            }
            .position(
                x: frame.minX + (frame.width / 2),
                y: geometry.size.height / 2
            )
        }
    }

    /// Close, split and new tab: standalone icon buttons on one floating card, readable over any page.
    private var actionButtons: some View {
        VStack(spacing: HarborDesign.Spacing.xxs) {
            Button(action: { peek.dismissPeek() }) {
                Image(systemName: "xmark")
            }
            // Disabled while the window is already split.
            Button(action: { peek.moveToSplitView() }) {
                Image(systemName: "square.split.2x1")
            }
            .disabled(!peek.canEnterSplitView)
            Button(action: { peek.moveToNewTab() }) {
                Image(systemName: "plus.square.on.square")
            }
        }
        .harborIconButtons()
        .padding(HarborDesign.Spacing.xxs)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
    }


    // MARK: - Layout Calculation

    private func calculateLayout(geometry: GeometryProxy) -> (frame: CGRect, cornerRadius: CGFloat) {
        let windowSize = geometry.size
        let sidebarPosition = harborSettings.sidebarPosition

        // Compute the visible web content area by excluding the sidebar width
        let sidebarWidth: CGFloat = windowState.isSidebarVisible ? windowState.sidebarWidth : 0
        let webAreaWidth = max(0, windowSize.width - sidebarWidth)

        // 80% of the web area wide and 90% of the window tall, so the page behind stays in view.
        let webViewHeight = windowSize.height * 0.9
        let cornerRadius: CGFloat = HarborDesign.Radius.xl

        // Center within the web area (excluding sidebar)
        let peekWidth = webAreaWidth * 0.8
        let peekXWithinWebArea = (webAreaWidth - peekWidth) / 2

        // Calculate peek X position based on sidebar position
        let peekX: CGFloat
        if sidebarPosition == .left {
            // Sidebar on left: peek window starts after sidebar
            peekX = sidebarWidth + peekXWithinWebArea
        } else {
            // Sidebar on right: peek window starts from left edge
            peekX = peekXWithinWebArea
        }


        return (
            frame: CGRect(
                x: peekX,
                y: 0,
                width: peekWidth,
                height: webViewHeight
            ),
            cornerRadius: cornerRadius
        )
    }
}
