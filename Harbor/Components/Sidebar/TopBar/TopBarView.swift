// Licensed under GPL-3.0. See LICENSE.
//
//  TopBarView.swift
//  Harbor
//
//  Created by Assistant on 23/09/2025.
//

import AppKit
import SwiftUI
import WebKit
import HarborDesign
import HarborWeb
import HarborUI

enum TopBarMetrics {
    static let height: CGFloat = 40
    /// Tucked away while the page scrolls down: just the site's name.
    static let collapsedHeight: CGFloat = 22
    /// The host's size tucked away against its size in the pill: 11pt caption over 13pt body.
    static let collapsedTextScale: CGFloat = 11.0 / 13.0
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 5
    static let pillMaxWidth: CGFloat = 520
    /// Keeps the centered address clear of the four navigation buttons.
    static let pillSideInset: CGFloat = 132
}

struct TopBarView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(\.harborSettings) var harborSettings
    @State private var isHovering: Bool = false
    @State private var previousTabId: UUID? = nil
    /// Reading down the page tucks the bar away; scrolling up, hovering it or a new page bring it back.
    @State private var isCollapsed = false

    var body: some View {
        let cornerRadius: CGFloat = harborSettings.hideWebContentBorder ? 0 : HarborDesign.Radius.pageCard

        ZStack {
            // Main content. Nothing is swapped out when the bar tucks away: the buttons fade and
            // shrink in place, the title after the host fades, and the host glides to the middle
            // and scales down to a caption, all on one spring with the bar's height.
            ZStack {
                HStack(spacing: HarborDesign.Spacing.sm) {
                    navigationControls
                    Spacer(minLength: 0)
                    trailingControls
                }
                .opacity(isCollapsed ? 0 : 1)
                .scaleEffect(isCollapsed ? 0.8 : 1)
                .blur(radius: isCollapsed ? 3 : 0)
                .allowsHitTesting(!isCollapsed)

                urlBar
                    .frame(maxWidth: TopBarMetrics.pillMaxWidth)
                    .padding(.horizontal, TopBarMetrics.pillSideInset)
            }
            .padding(.horizontal, TopBarMetrics.horizontalPadding)
            .padding(.vertical, isCollapsed ? 0 : TopBarMetrics.verticalPadding)
            .frame(maxWidth: .infinity)
            .frame(height: isCollapsed ? TopBarMetrics.collapsedHeight : TopBarMetrics.height)
            .contentShape(Rectangle())
            .onHoverTracking { hovering in
                if hovering && isCollapsed { setCollapsed(false) }
            }
            // The bar stands where the title bar would; double-clicking it does what one does.
            .onTapGesture(count: 2) {
                (NSApp.currentEvent?.window ?? NSApp.keyWindow)?.performTitleBarDoubleClick()
            }
            .background(topBarBackgroundColor)
            .animation(
                shouldAnimateColorChange ? HarborDesign.Motion.standard : nil,
                value: topBarBackgroundColor
            )
            .clipShape(
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: cornerRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .bottom) {
                // 1px bottom border - lighter when dark, darker when light
                Rectangle()
                    .fill(bottomBorderColor)
                    .frame(height: 1)
                    .animation(
                        shouldAnimateColorChange
                            ? HarborDesign.Motion.standard : nil,
                        value: bottomBorderColor
                    )
            }
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .preference(
                        key: URLBarFramePreferenceKey.self,
                        value: geometry.frame(in: .named("WindowSpace"))
                    )
            }
        )
        .onAppear {
            // Initialize previousTabId to the selection so the first color change doesn't animate
            previousTabId = windowState.selectedItemID
        }
        .onReceive(NotificationCenter.default.publisher(for: .harborPageScrolled)) { note in
            guard let view = note.object as? WKWebView, view === windowWebView,
                  let down = note.userInfo?["down"] as? Bool else { return }
            setCollapsed(down)
        }
        .onChange(of: session?.url) { _, _ in setCollapsed(false) }
        .onChange(of: windowState.selectedItemID) { oldId, newId in
            setCollapsed(false)
            previousTabId = oldId
            // Update previousTabId after a brief delay so the next color change within this page animates
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                previousTabId = newId
            }
        }
    }

    private var navigationControls: some View {
        HStack(spacing: 4) {
            // On the left the sidebar's own row holds only the space name, so the toggle lives here.
            if harborSettings.sidebarPosition == .left {
                Button("Toggle Sidebar", systemImage: "sidebar.left") {
                    browserManager.toggleSidebar(for: windowState)
                }
                .buttonStyle(HarborCircleButtonStyle(tint: navButtonColor))
            }
            Button("Go Back", systemImage: "chevron.backward", action: goBack)
                .buttonStyle(HarborCircleButtonStyle(tint: navButtonColor))
                .animation(
                    shouldAnimateColorChange ? HarborDesign.Motion.standard : nil,
                    value: navButtonColor
                )
                .disabled(!(session?.canGoBackOrReturn ?? false))
                .contextMenu {
                    NavigationHistoryContextMenu(
                        historyType: .back,
                        windowState: windowState
                    )
                }

            Button(
                "Go Forward",
                systemImage: "chevron.right",
                action: goForward
            )
            .buttonStyle(HarborCircleButtonStyle(tint: navButtonColor))
            .animation(
                shouldAnimateColorChange ? HarborDesign.Motion.standard : nil,
                value: navButtonColor
            )
            .disabled(!(session?.canGoForward ?? false))
            .contextMenu {
                NavigationHistoryContextMenu(
                    historyType: .forward,
                    windowState: windowState
                )
            }

            Button {
                if session?.isLoading == true {
                    session?.stop()
                } else {
                    refreshCurrentTab()
                }
            } label: {
                Image(systemName: session?.isLoading == true ? "xmark" : "arrow.clockwise")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(HarborCircleButtonStyle(tint: navButtonColor))
            .animation(
                shouldAnimateColorChange ? HarborDesign.Motion.standard : nil,
                value: navButtonColor
            )
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard collapsed != isCollapsed else { return }
        withAnimation(HarborDesign.Motion.barMorph) { isCollapsed = collapsed }
    }

    /// Pinned extensions and the extension library, at the trailing edge.
    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: HarborDesign.Spacing.xxs) {
            AssistantButton(tint: navButtonColor)
                .environmentObject(browserManager)
            if browserManager.tabs.selectedSession(in: windowState) != nil,
               let extensionManager = browserManager.extensionManager {
                let pinnedIDs = browserManager.harborSettings?.pinnedExtensionIDs ?? []
                let pinnedExtensions = extensionManager.installedExtensions.filter { pinnedIDs.contains($0.id) }
                if !pinnedExtensions.isEmpty {
                    ExtensionActionView(extensions: pinnedExtensions)
                        .environmentObject(browserManager)
                }
                ExtensionLibraryButton(tint: navButtonColor)
                    .environmentObject(browserManager)
                    .onAppear {
                        let installedIDs = extensionManager.installedExtensions
                            .filter { $0.isEnabled }
                            .map { $0.id }
                        browserManager.harborSettings?.migrateExtensionPinStateIfNeeded(installedExtensionIDs: installedIDs)
                    }
            }
        }
    }

    private var urlBar: some View {
        HStack(spacing: 0) {
            if browserManager.tabs.selectedSession(in: windowState) != nil {
                // Two texts so a narrow bar cuts the path or title first and then the host's
                // head: `accounts.google.com.x.evil.tld` must keep `evil.tld`.
                Text(displayURL.host)
                    .truncationMode(.head)
                    .layoutPriority(1)
                if !isCollapsed {
                    Text(displayURL.rest)
                        .truncationMode(.tail)
                        .transition(.opacity)
                }
            }
        }
        .font(HarborDesign.Font.body)
        .foregroundStyle(urlBarTextColor)
        .tracking(-0.1)
        .lineLimit(1)
        // Caption size when tucked away, scaled rather than re-set so it animates.
        .scaleEffect(isCollapsed ? TopBarMetrics.collapsedTextScale : 1)
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCollapsed ? 0 : HarborDesign.Spacing.sm)
        .padding(.horizontal, HarborDesign.Spacing.lg)
        .background(navButtonColor.opacity(isCollapsed ? 0 : (isHovering ? 0.12 : 0.07)))
        .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .contentShape(Rectangle())
        .onTapGesture {
            if let currentTab = browserManager.tabs.selectedSession(in: windowState) {
                commandPalette.openWithCurrentURL(currentTab.url)
            } else {
                commandPalette.open()
            }
        }
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovering = hovering
            }
        }
    }

    /// Nil while another window holds the page: its controls stay inert until Move Here.
    private var session: PageSession? {
        browserManager.tabs.controllableSession(in: windowState)
    }

    /// This window's own view of the page, so a clone navigates in its window.
    private var windowWebView: WKWebView? {
        session.flatMap { browserManager.webViewCoordinator?.getWebView(for: $0.itemID, in: windowState.id) }
    }

    private func goBack() {
        session?.goBack(in: windowWebView)
    }

    private func goForward() {
        if let webView = windowWebView { webView.goForward() } else { session?.goForward() }
    }

    private func refreshCurrentTab() {
        session?.refresh()
    }

    // Determine if we should animate color changes (within same tab) or snap (tab switch)
    private var shouldAnimateColorChange: Bool {
        let selectedItemID = browserManager.tabs.selectedSession(in: windowState)?.id
        return selectedItemID == previousTabId
    }

    // Top bar background color - matches top-right pixel of webview
    private var topBarBackgroundColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return Color(nsColor: topBarColor)
        }
        // Fallback to page background color if top bar color not available yet
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return Color(nsColor: pageColor)
        }
        // Fallback to system theme colors when no tab or color available
        // This ensures the top bar has a proper background even before page loads
        return Color(nsColor: .windowBackgroundColor)
    }

    // Nav button color - light on dark backgrounds, dark on light backgrounds
    private var navButtonColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return topBarColor.isPerceivedDark
                ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
        }
        // Fallback to page background color
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return pageColor.isPerceivedDark
                ? Color.white.opacity(0.9) : Color.black.opacity(0.8)
        }

        // Fallback
        return .primary
    }

    // Text color for URL bar - ensures proper contrast
    private var urlBarTextColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            return topBarColor.isPerceivedDark
                ? Color.white.opacity(0.55) : Color.black.opacity(0.8)
        }
        // Fallback to page background color
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            return pageColor.isPerceivedDark
                ? Color.white.opacity(0.55) : Color.black.opacity(0.8)
        }
        // Fallback to original text color logic
        return .primary
    }

    // Bottom border color - lighter when dark, darker when light
    private var bottomBorderColor: Color {
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let topBarColor = currentTab.topBarBackgroundColor
        {
            let baseColor = Color(nsColor: topBarColor)
            // Make lighter if dark, darker if light
            return adjustColorBrightness(
                baseColor,
                factor: topBarColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to page background color
        if let currentTab = browserManager.tabs.selectedSession(in: windowState),
            let pageColor = currentTab.pageBackgroundColor
        {
            let baseColor = Color(nsColor: pageColor)
            return adjustColorBrightness(
                baseColor,
                factor: pageColor.isPerceivedDark ? 1.2 : 0.85
            )
        }
        // Fallback to system separator color
        return Color(nsColor: .separatorColor)
    }

    // Helper to adjust color brightness
    private func adjustColorBrightness(_ color: Color, factor: CGFloat) -> Color
    {
        #if canImport(AppKit)
            guard let nsColor = NSColor(color).usingColorSpace(.sRGB) else {
                return color
            }
            var r: CGFloat = 0
            var g: CGFloat = 0
            var b: CGFloat = 0
            var a: CGFloat = 0
            nsColor.getRed(&r, green: &g, blue: &b, alpha: &a)

            // Clamp values between 0 and 1
            r = min(1.0, max(0.0, r * factor))
            g = min(1.0, max(0.0, g * factor))
            b = min(1.0, max(0.0, b * factor))

            return Color(
                nsColor: NSColor(srgbRed: r, green: g, blue: b, alpha: a)
            )
        #else
            return color
        #endif
    }

    private var displayURL: (host: AttributedString, rest: AttributedString) {
        guard let currentTab = browserManager.tabs.selectedSession(in: windowState)
        else {
            return ("", "")
        }

        return formatURL(
            currentTab.url,
            title: currentTab.title,
            isHovering: isHovering
        )
    }

    /// The host apart from what follows it, so each can truncate its own way.
    private func formatURL(_ url: URL, title: String?, isHovering: Bool)
        -> (host: AttributedString, rest: AttributedString)
    {
        if isHovering {
            guard let host = url.host else {
                return (AttributedString(url.absoluteString), "")
            }

            let cleanHost =
                host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

            let hostString = AttributedString(cleanHost)

            var pathString = AttributedString()

            if !url.path.isEmpty {
                pathString += AttributedString(url.path)
            }

            if let query = url.query {
                pathString += AttributedString("?" + query)
            }

            pathString.foregroundColor = urlBarTextColor.opacity(0.35)

            return (hostString, pathString)
        }

        guard let host = url.host else {
            return (AttributedString(url.absoluteString), "")
        }

        let cleanHost =
            host.hasPrefix("www.") ? String(host.dropFirst(4)) : host

        if url.path.isEmpty || url.path == "/" {
            return (AttributedString(cleanHost), "")
        } else {
            let displayTitle = title ?? cleanHost
            var titlePart = AttributedString(" / " + displayTitle)
            titlePart.foregroundColor = urlBarTextColor.opacity(0.35)
            return (AttributedString(cleanHost), titlePart)
        }
    }
}

