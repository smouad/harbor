// Licensed under GPL-3.0. See LICENSE.
//
//  WindowView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//  Updated by Aether Aurelia on 15/11/2025.
//

import AppKit
import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb
import HarborUI

/// Main window view that orchestrates the browser UI layout
struct WindowView: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(CommandPalette.self) private var commandPalette
    @Environment(WindowRegistry.self) private var windowRegistry
    @Environment(AIService.self) private var aiService
    @Environment(TabOrganizerManager.self) private var tabOrganizerManager
    @Environment(\.harborSettings) var harborSettings
    @Environment(\.openSettings) private var openSettings
    @StateObject private var hoverSidebarManager = HoverSidebarManager()
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        ZStack {
            WindowBackground()
                .contextMenu {
                    Button("Space Settings...") {
                        SettingsNavigation.shared.currentSettingsTab = .spaces
                        openSettings()
                    }
                    .disabled(windowState.spaceID.flatMap { tabs.space($0) } == nil)
                }

            SidebarWebViewStack()

            // Hover-reveal Sidebar overlay (slides in over web content)
            SidebarHoverOverlayView()
                .environmentObject(hoverSidebarManager)
                .environment(windowState)

            CommandPaletteView()
            DialogView()

            // Control-Tab: the recent-tabs list, shown until Control is let go.
            if let switcher = windowState.tabSwitcher {
                TabSwitcherView(switcher: switcher)
                    .environment(browserManager.tabs)
                    .transition(.opacity)
                    .zIndex(9500)
            }

            // Peek overlay for external link previews
            PeekOverlayView()

            // Find bar - always rendered (24/7), visibility controlled via opacity
            FindBarView(findManager: browserManager.findManager)
                .zIndex(10000)

        }
        // The window buttons sit in the sidebar's header, so they come and go with it.
        .background(TrafficLights(visible: windowState.isSidebarVisible || hoverSidebarManager.isOverlayVisible))
        .overlayPreferenceValue(DownloadsButtonAnchorKey.self) { anchor in
            DownloadFlightOverlay(target: anchor)
                .zIndex(8000)
        }
        // In-window, not a panel; see ExtensionLibraryOverlay.
        .overlayPreferenceValue(ExtensionLibraryAnchorKey.self) { anchor in
            ExtensionLibraryOverlay(anchor: anchor)
                .zIndex(9000)
        }
        .overlayPreferenceValue(FavoritePreviewAnchorKey.self) { anchor in
            FavoritePreviewOverlay(anchor: anchor)
                .zIndex(7000)
        }
        // System notification toasts - top trailing corner
        .overlay(alignment: .topTrailing) {
            VStack(spacing: 8) {
                // Tab closure toast
                if browserManager.showTabClosureToast && browserManager.tabClosureToastCount > 0 {
                    TabClosureToast()
                }

                // Copy URL toast
                if windowState.isShowingCopyURLToast {
                    CopyURLToast(title: windowState.copyToastText)
                        .environment(windowState)
                }
                
                // Shortcut conflict toast
                if windowState.isShowingShortcutConflictToast,
                   let conflictInfo = windowState.shortcutConflictInfo
                {
                    ShortcutConflictToast(
                        shortcut: conflictInfo.keyCombination.displayString,
                        websiteName: conflictInfo.websiteName,
                        harborActionName: conflictInfo.harborActionName
                    )
                        .environment(windowState)
                }
            }
            .padding(10)
            // Animate toast insertions/removals
            .animation(.smooth(duration: 0.25), value: browserManager.showTabClosureToast)
            .animation(.smooth(duration: 0.25), value: windowState.isShowingCopyURLToast)
            .animation(.smooth(duration: 0.25), value: windowState.isShowingShortcutConflictToast)
        }
        // Zoom control popup - separate from system toasts
        .overlay(alignment: .topTrailing) {
            if browserManager.shouldShowZoomPopup {
                ZoomPopupView(
                    zoomManager: browserManager.zoomManager,
                    onZoomIn: { browserManager.zoomInCurrentTab() },
                    onZoomOut: { browserManager.zoomOutCurrentTab() },
                    onZoomReset: { browserManager.resetZoomCurrentTab() },
                    onDismiss: { browserManager.shouldShowZoomPopup = false }
                )
                .transition(.scale(scale: 0.0, anchor: .top))
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: browserManager.shouldShowZoomPopup)
                .onTapGesture {
                    browserManager.shouldShowZoomPopup = false
                }
                .padding(10)
            }
        }
        // Lifecycle management
        .onAppear {
            browserManager.openSettingsAction = openSettings
            hoverSidebarManager.attach(browserManager: browserManager)
            hoverSidebarManager.windowRegistry = windowRegistry
            hoverSidebarManager.harborSettings = harborSettings
            hoverSidebarManager.start()
            applyAccent(spaceAccentHex)
        }
        .onDisappear {
            hoverSidebarManager.stop()
        }
        // Handle shortcut conflict notifications
        .onReceive(NotificationCenter.default.publisher(for: .shortcutConflictDetected)) { notification in
            if let conflictInfo = notification.userInfo?["conflictInfo"] as? ShortcutConflictInfo,
               conflictInfo.windowId == windowState.id {
                windowState.shortcutConflictInfo = conflictInfo
                windowState.isShowingShortcutConflictToast = true
                
                // Auto-dismiss after 1.5 seconds (slightly longer than the 1s timeout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if windowState.shortcutConflictInfo?.timestamp == conflictInfo.timestamp {
                        windowState.isShowingShortcutConflictToast = false
                    }
                }
            }
        }
        // Handle shortcut conflict dismissal
        .onReceive(NotificationCenter.default.publisher(for: .shortcutConflictDismissed)) { notification in
            if let windowId = notification.userInfo?["windowId"] as? UUID,
               windowId == windowState.id {
                windowState.isShowingShortcutConflictToast = false
            }
        }
        // The app-wide accent follows the active window's space.
        // Immediate, so the colour changes in the same frame as the page and URL.
        .onChange(of: spaceAccentHex) { _, hex in applyAccent(hex) }
        .onChange(of: windowRegistry.activeWindowId) { _, _ in applyAccent(spaceAccentHex) }
        // Handle organize tabs notification from keyboard shortcut manager
        .onReceive(NotificationCenter.default.publisher(for: .organizeTabsRequested)) { _ in
            guard windowRegistry.activeWindow?.id == windowState.id,
                  let spaceID = windowState.spaceID else { return }
            Task {
                await tabOrganizerManager.organizeTabs(in: spaceID, using: tabs)
            }
        }
        .environmentObject(browserManager)
        .environmentObject(browserManager.gradientColorManager)
        .environmentObject(browserManager.splitManager)
        .environmentObject(hoverSidebarManager)
        .preferredColorScheme(resolvedColorScheme)
    }

    /// Accent of the space this window shows; nil for private windows, which keep their own look.
    private var spaceAccentHex: String? {
        guard !windowState.isIncognito, let spaceID = windowState.spaceID else { return nil }
        return tabs.space(spaceID)?.accentHex
    }

    private func applyAccent(_ hex: String?) {
        guard let hex, windowRegistry.activeWindowId == windowState.id else { return }
        browserManager.gradientColorManager.setImmediate(SpaceGradient.accent(hex: hex))
    }

    /// The theme of the space this window shows. Private windows and the Agent space keep their own look.
    private var activeTheme: SpaceTheme? {
        guard !windowState.isIncognito, !showsAgentSpace, let spaceID = windowState.spaceID else { return nil }
        return tabs.space(spaceID)?.theme
    }

    private var resolvedColorScheme: ColorScheme? {
        // A theme set to light or dark decides for its space; automatic follows the app's setting.
        switch activeTheme?.mode {
        case .light: return .light
        case .dark: return .dark
        default: break
        }
        switch harborSettings.appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil  // Follow system appearance
        }
    }

    private var showsAgentSpace: Bool {
        windowState.spaceID != nil && windowState.spaceID == tabs.agentSpaceID
    }

    // MARK: - Layout Components

    @ViewBuilder
    private func WindowBackground() -> some View {
        // Private windows keep the neutral incognito accent, never the space's color.
        let accent = browserManager.accentColor(for: windowState)
        let isActive = windowRegistry.activeWindowId == windowState.id

        Group {
            if let theme = activeTheme {
                SpaceThemeBackground(theme: theme, isActive: isActive)
            } else {
                HarborDesign.Surface.containerGradient(accent: accent, isActive: isActive)
            }
        }
            // Private windows tint all chrome so they are never mistaken for a regular window.
            .overlay(windowState.isIncognito ? HarborDesign.Surface.privateTint : Color.clear)
            // So is the Agent space, with its fixed gradient.
            .overlay(Rectangle().fill(HarborDesign.Surface.agentGradient).opacity(showsAgentSpace ? HarborDesign.Surface.agentChromeOpacity : 0))
            // A themed space lays its own grain.
            .overlay { if activeTheme == nil { HarborGrain() } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .backgroundDraggable()
            .environment(windowState)
            .animation(HarborDesign.Motion.standard, value: isActive)
            // The chrome changes with the space (its color, its theme, the Agent's amber), and
            // fades with the slide instead of snapping a frame after it began.
            .animation(HarborDesign.Motion.standard, value: windowState.spaceID)
    }

    @ViewBuilder
    private func SidebarWebViewStack() -> some View {
        let aiVisible = windowState.isSidebarAIChatVisible
        let aiAppearsOnTrailingEdge = harborSettings.sidebarPosition == .left
        let sidebarVisible = windowState.isSidebarVisible
        let sidebarOnRight = harborSettings.sidebarPosition == .right
        let sidebarOnLeft = harborSettings.sidebarPosition == .left
        let bordered = !harborSettings.hideWebContentBorder

        HStack(spacing: 0) {
            if aiAppearsOnTrailingEdge {
                SpacesSidebar()
                WebContent()
                if aiVisible {
                    AISidebar()
                }
            } else {
                if aiVisible {
                    AISidebar()
                }
                WebContent()
                SpacesSidebar()
            }
        }
        // Apply padding similar to regular sidebar: remove padding when sidebar/AI is visible on that side
        // When sidebar is on left, AI appears on right (trailing); when sidebar is on right, AI appears on left (leading)
        .padding(.trailing, !bordered || (sidebarVisible && sidebarOnRight) || (aiVisible && sidebarOnLeft) ? 0 : 8)
        .padding(.leading, !bordered || (sidebarVisible && sidebarOnLeft) || (aiVisible && sidebarOnRight) ? 0 : 8)
    }

    /// Kept alive while hidden. Building the sidebar again on every reopen (each space's page,
    /// its favicons and rows) was what made it lag on the way back; hidden, it keeps its full
    /// width under a clip that closes to nothing, so it slides out and back in.
    @ViewBuilder
    private func SpacesSidebar() -> some View {
        let isVisible = windowState.isSidebarVisible
        let onLeft = harborSettings.sidebarPosition == .left
        SpacesSideBarView()
            .frame(width: windowState.sidebarWidth)
            .overlay(alignment: onLeft ? .trailing : .leading) {
                if isVisible {
                    SidebarResizeView()
                        .frame(maxHeight: .infinity)
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .zIndex(2000)
                        .environment(windowState)
                }
            }
            .environmentObject(browserManager)
            .environment(windowState)
            .environment(commandPalette)
            .environmentObject(browserManager.gradientColorManager)
            .frame(width: isVisible ? windowState.sidebarWidth : 0, alignment: onLeft ? .trailing : .leading)
            .clipped()
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }

    @ViewBuilder
    private func WebContent() -> some View {
        let cornerRadius = HarborDesign.Radius.pageCard
        
        let hasTopBar = harborSettings.topBarAddressView
        let bordered = !harborSettings.hideWebContentBorder

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if bordered {
                    WebsiteLoadingIndicator()
                        .zIndex(3000)
                }

                if hasTopBar {
                    TopBarView()
                        .environmentObject(browserManager)
                        .environment(windowState)
                        .zIndex(2500)
                }

                WebsiteView()
                    .zIndex(2000)
            }

            // Shadow shape positioned behind both top bar and webview
            // The webview will block the bottom shadow, leaving only top/left/right shadows visible
            if hasTopBar && bordered {
                UnevenRoundedRectangle(
                    topLeadingRadius: cornerRadius + 1,
                    bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0,
                    topTrailingRadius: cornerRadius + 1,
                    style: .continuous
                )
                .frame(height: TopBarMetrics.height)
                .frame(maxWidth: .infinity)
                .offset(y: 8)
                .shadow(color: Color.black.opacity(0.3), radius: 4, x: 0, y: 0)
                .allowsHitTesting(false)
                .zIndex(-1)
            }

            // No inset to sit in, so it floats over the page's top edge.
            if !bordered {
                WebsiteLoadingIndicator()
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if aiService.isExecutingTools {
                ToolExecutionGlowView()
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
                    .allowsHitTesting(false)
            }
        }
        .padding(.bottom, bordered ? 8 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func AISidebar() -> some View {
        let handleAlignment: Alignment = harborSettings.sidebarPosition == .left ? .leading : .trailing
        
        DevPanelColumn()
            .frame(width: windowState.aiSidebarWidth)
            .overlay(alignment: handleAlignment) {
                AISidebarResizeView()
                    .frame(maxHeight: .infinity)
                    .environmentObject(browserManager)
                    .environment(windowState)
            }
            .transition(
                .move(edge: harborSettings.sidebarPosition == .left ? .trailing : .leading)
                .combined(with: .opacity)
            )
            .environmentObject(browserManager)
            .environment(windowState)
            .environment(harborSettings)
    }

    private func websiteColumnClipShape(cornerRadius: CGFloat, hasTopBar: Bool) -> AnyShape {
        if hasTopBar {
            return AnyShape(UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: cornerRadius,
                bottomTrailingRadius: cornerRadius,
                topTrailingRadius: 0,
                style: .continuous
            ))
        } else {
            return AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private struct TrafficLights: NSViewRepresentable {
    let visible: Bool

    func makeNSView(context: Context) -> TrafficLightsView { TrafficLightsView() }
    func updateNSView(_ view: TrafficLightsView, context: Context) { view.visible = visible }
}

/// The only code that shows or hides the window buttons. Leaving full screen paints a frame with
/// them at the bare inset before the toolbar is back, so they stay hidden until the exit ends.
private final class TrafficLightsView: NSView {
    var visible = true {
        didSet { if visible != oldValue { apply() } }
    }
    private var exitingFullScreen = false
    private var observers: [any NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setExiting(true) }
            },
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setExiting(false) }
            },
        ]
        apply()
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func setExiting(_ exiting: Bool) {
        exitingFullScreen = exiting
        apply()
    }

    private func apply() {
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(type)?.isHidden = !visible || exitingFullScreen
        }
    }
}
