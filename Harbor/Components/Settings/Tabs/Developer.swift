// Licensed under GPL-3.0. See LICENSE.
//
//  Developer.swift
//  Harbor
//
//  Developer Mode and Browser Control.
//

import HarborSettings
import SwiftUI
import HarborDesign

struct SettingsDeveloperTab: View {
    @Environment(\.harborSettings) var harborSettings
    @EnvironmentObject var browserManager: BrowserManager

    var body: some View {
        @Bindable var settings = harborSettings
        Form {
            Section {
                Toggle("Developer Mode", isOn: $settings.developerModeEnabled)
                    .onChange(of: settings.developerModeEnabled) { _, on in
                        browserManager.tabs.setDeveloperMode(on)
                        DevMCPServer.shared.applyEnabledSetting(on && settings.browserControlServerEnabled)
                    }
            } footer: {
                Text("Shows developer tools and lets you turn on Browser Control.")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $settings.browserControlServerEnabled) {
                    VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                        Text("Allow agents to control this browser")
                            .font(HarborDesign.Font.body)
                        Text("Serves MCP on 127.0.0.1:47823 so a coding agent can drive Harbor")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!settings.developerModeEnabled)
                // The setting lives in HarborSettings, which cannot reach the server; start and
                // stop it from here so the toggle still takes effect without a relaunch.
                .onChange(of: settings.browserControlServerEnabled) {
                    DevMCPServer.shared.applyEnabledSetting($1 && settings.developerModeEnabled)
                }
            } header: {
                Text("Browser Control")
            } footer: {
                Text("A client must send the token from Application Support/com.mouad.harbor/dev-mcp-token. Any program on this Mac can read that file, and with it run JavaScript in your tabs and read pages you are signed in to. Leave this off unless you are driving Harbor from an agent.")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.developerModeEnabled && settings.browserControlServerEnabled {
                AgentVaultSection()
            }
        }
        .formStyle(.grouped)
    }
}
