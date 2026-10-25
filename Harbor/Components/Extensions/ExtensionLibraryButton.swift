// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionLibraryButton.swift
//  Harbor
//

import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct ExtensionLibraryButton: View {
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    /// The icon's color over a page, as the top bar's other buttons take it. `.primary` follows
    /// the app's appearance, not the page, so on a white page in a dark app the icon vanished.
    var tint: Color?

    var body: some View {
        // Site controls: sharing, extensions and this site's settings, as Arc's sliders button.
        let button = Button("Site Controls", systemImage: "slider.horizontal.3") {
            windowState.isExtensionLibraryVisible.toggle()
        }
        .labelStyle(.iconOnly)
        Group {
            if let tint {
                button.buttonStyle(HarborCircleButtonStyle(tint: tint))
            } else {
                button
                    .buttonStyle(HarborIconButtonStyle(size: HarborDesign.Size.iconButton, radius: HarborDesign.Radius.sm))
                    .foregroundStyle(Color.primary)
            }
        }
        // The overlay in WindowView hangs off this frame.
        .anchorPreference(key: ExtensionLibraryAnchorKey.self, value: .bounds) { $0 }
    }
}
