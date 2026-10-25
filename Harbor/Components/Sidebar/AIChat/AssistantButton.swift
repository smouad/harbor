// Licensed under GPL-3.0. See LICENSE.
//
//  AssistantButton.swift
//  Harbor
//
//  The sparkle button that opens and closes Ask Harbor, the AI Assistant. It sits in the top bar
//  when the address bar is on top, and beside the New button in the sidebar's bottom bar when it
//  is in the sidebar, so it is on screen in either layout.
//

import SwiftUI
import HarborDesign
import HarborUI
import HarborWeb

struct AssistantButton: View {
    /// The icon's color over a page, as the top bar's other buttons take it; nil on the sidebar.
    var tint: Color?

    @EnvironmentObject var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.harborSettings) private var harborSettings

    var body: some View {
        if harborSettings.showAIAssistant {
            if let tint {
                button.buttonStyle(HarborCircleButtonStyle(tint: tint))
            } else {
                button.harborIconButtons()
            }
        }
    }

    private var button: some View {
        Button("Toggle AI Assistant", systemImage: "sparkle") {
            browserManager.toggleAISidebar(for: windowState)
        }
    }
}
