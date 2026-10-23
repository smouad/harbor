// Licensed under GPL-3.0. See LICENSE.
//
//  SplitPaneView.swift
//  Harbor
//
//  One pane of the split view: the page, with controls floating over it. The compositor keeps
//  panes across refreshes so a web view never leaves its superview while the pair holds.
//

import AppKit
import SwiftUI
import WebKit
import HarborDesign
import HarborSettings
import HarborTabsCore
import HarborUI
import HarborWeb

final class SplitPaneView: NSView {
    // A CGColor is frozen at creation; re-resolve it when light/dark changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    let side: SplitViewManager.Side
    let itemID: UUID
    /// The page view's parent. It fills the pane; the controls float over it.
    let content = NSView()
    private let maskLayer = CAShapeLayer()
    private weak var settings: HarborSettingsService?

    init(frame: NSRect, side: SplitViewManager.Side, itemID: UUID, browserManager: BrowserManager, windowState: BrowserWindowState) {
        self.side = side
        self.itemID = itemID
        self.settings = browserManager.harborSettings
        super.init(frame: frame)
        wantsLayer = true
        layer?.mask = maskLayer
        viewDidChangeEffectiveAppearance()
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        // Each control is its own hosting view sized to its content, so the rest of the pane
        // passes clicks to the page.
        func host(_ view: some View) -> NSView {
            let host = NSHostingView(rootView: view
                .environment(browserManager.tabs)
                .environment(windowState)
                .environment(\.tabActions, browserManager))
            host.translatesAutoresizingMaskIntoConstraints = false
            host.safeAreaRegions = []
            addSubview(host)
            return host
        }
        let title = host(SplitPaneTitle(itemID: itemID))
        let buttons = host(SplitPaneButtons(itemID: itemID))
        let inset = HarborDesign.Spacing.md
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            title.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -inset),
            buttons.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
        ])
        updateMask()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Puts `view` in the pane, leaving it alone when it is already there.
    func show(_ view: NSView) {
        if view.superview !== content {
            content.subviews.forEach {
                ($0 as? WKWebView)?.closeWebInspector()
                $0.removeFromSuperview()
            }
            content.addSubview(view)
            view.frame = content.bounds
        } else if !content.subviews.contains(where: \.isWebInspectorView) {
            // WebKit sizes the page and a docked inspector together; leave them be.
            view.frame = content.bounds
        }
        view.autoresizingMask = [.width, .height]
        view.isHidden = false
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateMask()
    }

    private func updateMask() {
        let radius = HarborDesign.Radius.md
        // Toggling the border resizes the pane, so this reruns through setFrameSize.
        let outer = settings?.hideWebContentBorder == true ? 0 : radius
        maskLayer.path = TabCompositorWrapper.createUnevenRoundedRectPath(
            rect: bounds,
            topLeadingRadius: side == .left ? 0 : radius,
            bottomLeadingRadius: side == .left ? outer : radius,
            bottomTrailingRadius: side == .right ? outer : radius,
            topTrailingRadius: side == .right ? 0 : radius
        )
    }
}

/// What the pane shows, floating at its top leading corner.
private struct SplitPaneTitle: View {
    let itemID: UUID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    var body: some View {
        if let item = tabs.item(itemID) {
            HStack(spacing: HarborDesign.Spacing.sm) {
                ItemFavicon(item: item, session: tabs.session(for: itemID))
                    .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
                Text(tabs.title(for: item))
                    .font(HarborDesign.Font.secondary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.navRow)
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
            .onTapGesture { tabs.select(itemID, in: windowState) }
            .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
    }
}

/// Separate and close, floating at the pane's top trailing corner in one group.
private struct SplitPaneButtons: View {
    let itemID: UUID

    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.tabActions) private var actions

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.xxs) {
            SplitPaneButton(systemImage: "rectangle.split.2x1.slash", help: "Separate Tabs") {
                actions?.separateSplit(in: windowState)
            }
            SplitPaneButton(systemImage: "xmark", help: "Close Tab") {
                tabs.close(itemID)
            }
        }
        .padding(.horizontal, HarborDesign.Spacing.xs)
        .frame(height: HarborDesign.Size.navRow)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
    }
}

private struct SplitPaneButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(HarborDesign.Font.secondary)
                .foregroundStyle(.primary)
                .frame(width: HarborDesign.Size.rowButton, height: HarborDesign.Size.rowButton)
                .background(isHovering ? HarborDesign.Surface.fillPressed : Color.clear)
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
        }
        .buttonStyle(PlainButtonStyle())
        .help(help)
        .onHoverTracking { isHovering = $0 }
    }
}
