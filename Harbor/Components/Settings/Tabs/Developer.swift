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
                Section {
                    Picker("Your tabs", selection: $settings.agentTabAccess) {
                        Text("Agent space only").tag(AgentTabAccess.off)
                        Text("Ask for each tab").tag(AgentTabAccess.ask)
                        Text("Any tab").tag(AgentTabAccess.always)
                    }
                    Toggle("Extensions in agent tabs", isOn: $settings.agentExtensionsEnabled)
                    Toggle("Switch to Chrome where Safari is turned away", isOn: $settings.agentPresentsAsChrome)
                } header: {
                    Text("Agents")
                } footer: {
                    Text("Agents work in the Agent space. With Ask for each tab, an agent can also use one of your tabs once you allow it on its card; with Any tab, without asking. A tab an agent is using shows the Agent frame. Extensions apply to tabs opened after the change. When a site tells an agent its browser is not supported, the agent's tabs present as Chrome there from then on.")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }

                AgentVaultSection()
            }
        }
        .formStyle(.grouped)
    }
}
