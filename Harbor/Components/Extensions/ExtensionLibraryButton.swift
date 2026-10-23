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

    var body: some View {
        // Site controls: sharing, extensions and this site's settings, as Arc's sliders button.
        Button("Site Controls", systemImage: "slider.horizontal.3") {
            windowState.isExtensionLibraryVisible.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HarborIconButtonStyle(size: HarborDesign.Size.iconButton, radius: HarborDesign.Radius.sm))
        .foregroundStyle(Color.primary)
        // The overlay in WindowView hangs off this frame.
        .anchorPreference(key: ExtensionLibraryAnchorKey.self, value: .bounds) { $0 }
    }
}
