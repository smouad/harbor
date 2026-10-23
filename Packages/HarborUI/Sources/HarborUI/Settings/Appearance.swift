// Licensed under GPL-3.0. See LICENSE.
//
//  Appearance.swift
//  Harbor
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import HarborSettings
import SwiftUI

public struct SettingsAppearanceTab: View {
    @Environment(HarborSettingsService.self) var harborSettings


    public init() {}

    public var body: some View {
        @Bindable var settings = harborSettings
        Form {
            Section("Theme") {
                Picker("Appearance", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            // Every row here is about the Mac window: a sidebar side, the
            // floating URL bar, and a hover preview. None has a touch meaning.
            #if os(macOS)
            Section("Layout") {
                Picker("Sidebar Position", selection: $settings.sidebarPosition) {
                    ForEach(SidebarPosition.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Toggle("Show URL bar in the web view", isOn: $settings.topBarAddressView)
                Toggle("Preview link URL on hover", isOn: $settings.showLinkStatusBar)
                Toggle("Show previews when hovering favorites", isOn: $settings.favoritePreviews)
                Toggle("Hide border", isOn: $settings.hideWebContentBorder)
            }
            #endif
        }
        .formStyle(.grouped)
    }
}
