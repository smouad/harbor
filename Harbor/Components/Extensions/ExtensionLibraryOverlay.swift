// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryOverlay.swift
//  Harbor
//
//  Created by Bain Gurley on 21/09/2026.
//

import SwiftUI
import HarborDesign
import HarborWeb

/// Where the URL bar's overflow button sits, reported so the overlay can hang off it.
struct ExtensionLibraryAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// Site controls (`ExtensionLibraryView`), drawn inside the window rather than in an
/// `NSPanel`: a key panel gets a heavier window shadow that squares off at its own edge, and
/// in-window needs no event monitors to dismiss.
struct ExtensionLibraryOverlay: View {
    let anchor: Anchor<CGRect>?

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState

    private let menuWidth: CGFloat = 264
    private let gap: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            if windowState.isExtensionLibraryVisible,
               let settings = browserManager.harborSettings,
               let anchor {
                let buttonFrame = proxy[anchor]

                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { close() }

                    ExtensionLibraryView(
                        browserManager: browserManager,
                        windowState: windowState,
                        settings: settings,
                        onDismiss: { close() }
                    )
                    .frame(width: menuWidth)
                    .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.xl))
                    .fixedSize()
                    .offset(x: originX(buttonFrame: buttonFrame, container: proxy.size),
                            y: buttonFrame.maxY + gap)
                }
                .onExitCommand { close() }
                .onChange(of: windowState.selectedItemID) { _, _ in close() }
            }
        }
        .ignoresSafeArea()
    }

    /// Centred under the button, clamped so a narrow window cannot push it off screen.
    private func originX(buttonFrame: CGRect, container: CGSize) -> CGFloat {
        let preferred = buttonFrame.midX - menuWidth / 2
        let maxX = max(gap, container.width - menuWidth - gap)
        return min(max(gap, preferred), maxX)
    }

    private func close() {
        windowState.isExtensionLibraryVisible = false
    }
}
