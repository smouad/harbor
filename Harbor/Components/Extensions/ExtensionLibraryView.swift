// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryView.swift
//  Harbor
//
//  Site controls, the panel under the address bar's sliders button, laid out as Arc lays its
//  own: four actions across the top, the extensions as a grid of tiles, the site's settings
//  as rows that say their state, and a footer with the connection's security and a menu for
//  the rest.
//

import AppKit
import os
import SwiftUI
import WebKit

import HarborBlocker
import HarborDesign
import HarborSettings
import HarborWeb
import HarborUI

struct ExtensionLibraryView: View {
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let settings: HarborSettingsService
    let onDismiss: () -> Void

    @Environment(\.openSettings) private var openSettings
    @State private var isBlocking = true
    @State private var isConfirmingClearCookies = false

    private var currentTab: PageSession? {
        browserManager.tabs.selectedSession(in: windowState)
    }

    private var currentHost: String? {
        currentTab?.url.host
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xl) {
            actions
            extensionsSection
            if currentHost != nil {
                settingsSection
            }
            Divider().opacity(0.5)
            footer
        }
        .padding(HarborDesign.Spacing.lg)
        .frame(width: 264)
        .confirmationDialog(
            "Clear cookies for this site?",
            isPresented: $isConfirmingClearCookies
        ) {
            Button("Clear Cookies", role: .destructive) { clearCookies() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will be signed out of this site.")
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            if let url = currentTab?.url {
                ShareLink(item: url) {
                    ActionTileLabel(systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .help("Share")
                .accessibilityLabel("Share")
            } else {
                ActionTile(systemImage: "square.and.arrow.up", help: "Share") {}
                    .disabled(true)
            }

            ConfirmingActionTile(systemImage: "link", help: "Copy Link") {
                guard let url = currentTab?.url.absoluteString else { return false }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                return true
            }
            .disabled(currentTab == nil)

            ScreenshotTile(webView: currentTab?.webView)

            let isPiPActive = currentTab?.hasPiPActive == true
            ActionTile(
                systemImage: isPiPActive ? "pip.exit" : "pip.enter",
                help: isPiPActive ? "Exit Picture in Picture" : "Picture in Picture"
            ) {
                currentTab?.requestPictureInPicture()
                onDismiss()
            }
            .disabled(!(currentTab.map { $0.hasVideoContent || $0.hasPiPActive } ?? false))
        }
    }

    // MARK: - Extensions

    private var extensionsSection: some View {
        let extensions = browserManager.extensionManager?.installedExtensions.filter { $0.isEnabled } ?? []
        return VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            sectionTitle("Extensions")
            ScrollView {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: HarborDesign.Spacing.md), count: 4),
                    spacing: HarborDesign.Spacing.md
                ) {
                    ForEach(extensions, id: \.id) { ext in
                        ExtensionGridItem(
                            ext: ext,
                            isPinned: settings.pinnedExtensionIDs.contains(ext.id),
                            browserManager: browserManager,
                            windowState: windowState,
                            settings: settings
                        )
                    }
                    ActionTile(systemImage: "plus", help: "Add Extension") {
                        ExtensionManager.shared.showExtensionInstallDialog()
                    }
                }
            }
            .frame(maxHeight: 200)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.sm) {
            sectionTitle("Settings")

            SettingRow(
                systemImage: "shield.lefthalf.filled",
                title: "Ad Blocker",
                state: isBlocking ? "On" : "Off for this site",
                isOn: isBlocking
            ) {
                setBlocking(!isBlocking)
            }
            .onAppear(perform: readBlocking)
            .onChange(of: currentHost) { _, _ in readBlocking() }

            if let host = currentHost {
                PermissionRow(permission: .microphone, systemImage: "mic.fill", title: "Microphone", host: host, settings: settings)
                PermissionRow(permission: .camera, systemImage: "video.fill", title: "Camera", host: host, settings: settings)
            }

            if let tab = currentTab {
                SettingRow(
                    systemImage: tab.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: "Sound",
                    state: tab.isAudioMuted ? "Muted" : "On",
                    isOn: !tab.isAudioMuted
                ) {
                    tab.toggleMute()
                }

                SettingRow(
                    systemImage: "pip",
                    title: "Automatic Picture in Picture",
                    state: settings.autoPictureInPicture ? "On" : "Off",
                    isOn: settings.autoPictureInPicture
                ) {
                    settings.autoPictureInPicture.toggle()
                }

                SettingRow(
                    systemImage: "plus.magnifyingglass",
                    title: "Zoom",
                    state: "\(browserManager.zoomManager.currentZoomPercentage)%",
                    isOn: browserManager.zoomManager.currentZoomPercentage == 100
                ) {
                    zoom(reset: true)
                } trailing: {
                    HStack(spacing: HarborDesign.Spacing.xxs) {
                        Button("Zoom Out", systemImage: "minus") { zoom(by: -1) }
                        Button("Zoom In", systemImage: "plus") { zoom(by: 1) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(HarborIconButtonStyle(size: HarborDesign.Size.rowButton + 4, radius: HarborDesign.Radius.sm))
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let scheme = currentTab?.url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
                let secure = scheme == "https"
                Label(secure ? "Secure" : "Not Secure", systemImage: secure ? "lock.fill" : "lock.open.fill")
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(secure ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.orange))
                    .padding(.horizontal, HarborDesign.Spacing.lg)
                    .frame(height: HarborDesign.Size.iconButton)
                    .background(HarborDesign.Surface.fill, in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
                    .help(currentHost ?? "")
            }

            Spacer()

            Menu {
                Button("Clear Cache") { clearCache() }
                    .disabled(currentHost == nil)
                Button("Clear Cookies…") { isConfirmingClearCookies = true }
                    .disabled(currentHost == nil)
                Button("Copy Title") { copyTitle() }
                    .disabled(currentTab == nil)
                Divider()
                Button("Manage Extensions…") { openSettingsTab(.extensions) }
                Button("Add Extension…") {
                    onDismiss()
                    ExtensionManager.shared.showExtensionInstallDialog()
                }
                Divider()
                Button("All Site Settings…") { openSettingsTab(.privacy) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(HarborDesign.Font.body)
                    .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                    .background(HarborDesign.Surface.fill, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(HarborDesign.Font.title)
            .foregroundStyle(.primary)
    }

    // MARK: - Helpers

    private func readBlocking() {
        guard let host = currentHost else { return }
        isBlocking = !browserManager.contentBlockerManager.isDomainAllowed(host)
    }

    private func setBlocking(_ blocking: Bool) {
        guard let host = currentHost else { return }
        browserManager.contentBlockerManager.allowDomain(host, allowed: !blocking)
        withAnimation(HarborDesign.Motion.quick) { isBlocking = blocking }
    }

    private func zoom(by step: Int = 0, reset: Bool = false) {
        guard let tab = currentTab, let webView = tab.webView else { return }
        if reset {
            browserManager.zoomManager.resetZoom(for: webView, tabId: tab.itemID)
        } else if step > 0 {
            browserManager.zoomManager.zoomIn(for: webView, tabId: tab.itemID)
        } else {
            browserManager.zoomManager.zoomOut(for: webView, tabId: tab.itemID)
        }
    }

    /// Caches and stored data, not cookies, so the person stays signed in.
    private func clearCache() {
        guard let host = currentHost else { return }
        Task { await browserManager.cacheManager.clearCacheForDomainExcludingCookies(host) }
    }

    private func clearCookies() {
        guard let host = currentHost else { return }
        Task { await browserManager.cookieManager.deleteCookiesForDomain(host) }
    }

    private func copyTitle() {
        guard let title = currentTab?.title else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(title, forType: .string)
    }

    private func openSettingsTab(_ tab: SettingsTabs) {
        onDismiss()
        SettingsNavigation.shared.currentSettingsTab = tab
        openSettings()
    }
}

// MARK: - Action Tiles

/// One of the actions across the top: a wide tile with a symbol, its name in the tooltip.
private struct ActionTileLabel: View {
    let systemImage: String
    var tint: Color = .primary

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(HarborDesign.Font.title)
            .foregroundStyle(isEnabled ? AnyShapeStyle(tint) : AnyShapeStyle(.tertiary))
            .contentTransition(.symbolEffect(.replace))
            .frame(maxWidth: .infinity)
            .frame(height: HarborDesign.Size.chromeControl + 6)
            .background(
                isHovering && isEnabled ? HarborDesign.Surface.fillPressed : HarborDesign.Surface.fill,
                in: HarborDesign.Radius.shape(HarborDesign.Radius.tile)
            )
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.tile))
            .onHoverTracking { isHovering = $0 }
    }
}

private struct ActionTile: View {
    let systemImage: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ActionTileLabel(systemImage: systemImage, tint: tint)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// An action that shows a check mark for a moment when it worked.
private struct ConfirmingActionTile: View {
    let systemImage: String
    let help: String
    let action: () -> Bool

    @State private var didSucceed = false

    var body: some View {
        ActionTile(
            systemImage: didSucceed ? "checkmark" : systemImage,
            help: didSucceed ? "Copied" : help,
            tint: didSucceed ? .green : .primary
        ) {
            guard action() else { return }
            withAnimation(HarborDesign.Motion.quick) { didSucceed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(HarborDesign.Motion.quick) { didSucceed = false }
            }
        }
    }
}

/// Copies the visible part of the page to the clipboard as an image.
private struct ScreenshotTile: View {
    let webView: WKWebView?

    @State private var didCopy = false

    var body: some View {
        ActionTile(
            systemImage: didCopy ? "checkmark" : "camera",
            help: didCopy ? "Screenshot copied" : "Copy Screenshot",
            tint: didCopy ? .green : .primary
        ) {
            webView?.takeSnapshot(with: nil) { image, _ in
                guard let image else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
                withAnimation(HarborDesign.Motion.quick) { didCopy = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(HarborDesign.Motion.quick) { didCopy = false }
                }
            }
        }
        .disabled(webView == nil)
    }
}

// MARK: - Settings Rows

/// What a site setting row shows: a round symbol that is filled while the setting is on, its
/// name, and what it is set to.
private struct SettingRowLabel: View {
    let systemImage: String
    let title: String
    let state: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            Image(systemName: systemImage)
                .font(HarborDesign.Font.body)
                .foregroundStyle(isOn ? Color.black.opacity(0.85) : Color.secondary)
                .frame(width: HarborDesign.Size.iconButton + 4, height: HarborDesign.Size.iconButton + 4)
                .background(Circle().fill(isOn ? Color.white.opacity(0.92) : HarborDesign.Surface.fillPressed))
                .overlay(Circle().strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(HarborDesign.Font.label)
                    .foregroundStyle(.primary)
                Text(state)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .animation(HarborDesign.Motion.quick, value: isOn)
        .accessibilityElement(children: .combine)
    }
}

/// A row with the hover fill every setting shares, and room at the end for extra controls.
private struct SettingRowChrome<Content: View, Trailing: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            content()
            trailing()
        }
        .padding(.horizontal, HarborDesign.Spacing.xs)
        .padding(.vertical, HarborDesign.Spacing.xxs)
        .background(
            HarborDesign.Radius.shape(HarborDesign.Radius.md)
                .fill(isHovering ? HarborDesign.Surface.fill : .clear)
        )
        .onHoverTracking { isHovering = $0 }
    }
}

/// A setting changed by clicking its row.
private struct SettingRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    let state: String
    let isOn: Bool
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingRowChrome {
            Button(action: action) {
                SettingRowLabel(systemImage: systemImage, title: title, state: state, isOn: isOn)
            }
            .buttonStyle(.plain)
        } trailing: {
            trailing()
        }
    }
}

extension SettingRow where Trailing == EmptyView {
    init(systemImage: String, title: String, state: String, isOn: Bool, action: @escaping () -> Void) {
        self.init(systemImage: systemImage, title: title, state: state, isOn: isOn, action: action) { EmptyView() }
    }
}

/// Camera or microphone for this site: Ask, Allowed or Blocked, picked from a menu.
private struct PermissionRow: View {
    let permission: SitePermission
    let systemImage: String
    let title: String
    let host: String
    let settings: HarborSettingsService

    private var policy: SitePermissionPolicy { settings.permission(permission, for: host) }

    private var state: String {
        switch policy {
        case .ask: return "Ask"
        case .allow: return "Allowed"
        case .block: return "Blocked"
        }
    }

    var body: some View {
        SettingRowChrome {
            Menu {
                Picker(title, selection: Binding(
                    get: { policy },
                    set: { settings.setPermission(permission, to: $0, for: host) }
                )) {
                    ForEach(SitePermissionPolicy.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                SettingRowLabel(systemImage: systemImage, title: title, state: state, isOn: policy == .allow)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        } trailing: {
            EmptyView()
        }
    }
}

// MARK: - Extension Grid Item

/// An extension as a tile; clicking it runs the extension's action, as its toolbar button would.
private struct ExtensionGridItem: View {
    let ext: InstalledExtension
    let isPinned: Bool
    let browserManager: BrowserManager
    let windowState: BrowserWindowState
    let settings: HarborSettingsService

    @State private var isHovering = false
    @State private var badgeText: String?

    var body: some View {
        Button {
            triggerExtensionAction()
        } label: {
            Group {
                if let iconPath = ext.iconPath,
                   let nsImage = NSImage(contentsOfFile: iconPath) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(HarborDesign.Font.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: HarborDesign.Size.chromeControl + 6)
            .background(
                isHovering ? HarborDesign.Surface.fillPressed : HarborDesign.Surface.fill,
                in: HarborDesign.Radius.shape(HarborDesign.Radius.tile)
            )
            .overlay(alignment: .topTrailing) {
                if let badge = badgeText, !badge.isEmpty {
                    Text(badge)
                        .font(HarborDesign.Font.micro)
                        .foregroundStyle(.white)
                        .padding(.horizontal, HarborDesign.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Color.red, in: Capsule())
                        .offset(x: 3, y: -3)
                } else if isPinned {
                    Image(systemName: "pin.fill")
                        .font(HarborDesign.Font.micro)
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(45))
                        .padding(HarborDesign.Spacing.xs)
                }
            }
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.tile))
        }
        .buttonStyle(.plain)
        .help(ext.name)
        .onHoverTracking { isHovering = $0 }
        .onAppear { refreshBadge() }
        .contextMenu {
            if isPinned {
                Button("Unpin from Address Bar") {
                    settings.pinnedExtensionIDs.removeAll { $0 == ext.id }
                }
            } else {
                Button("Pin to Address Bar") {
                    settings.pinnedExtensionIDs.append(ext.id)
                }
            }
        }
        .accessibilityLabel(ext.name)
        .accessibilityAddTraits(.isButton)
    }

    private func triggerExtensionAction() {
        guard let ctx = ExtensionManager.shared.getExtensionContext(for: ext.id) else { return }

        if ctx.webExtension.hasBackgroundContent {
            ctx.loadBackgroundContent { error in
                if let error { Logger(subsystem: "com.harbor.browser", category: "ExtensionLibrary").error("Background wake failed: \(error.localizedDescription, privacy: .public)") }
            }
        }

        let adapter = ExtensionManager.shared.actionAdapter(in: windowState)
        ExtensionManager.shared.performAction(ctx, for: adapter)
    }

    private func refreshBadge() {
        guard let ctx = ExtensionManager.shared.getExtensionContext(for: ext.id) else {
            badgeText = nil
            return
        }
        let adapter = ExtensionManager.shared.actionAdapter(in: windowState)
        badgeText = ctx.action(for: adapter)?.badgeText
    }
}
