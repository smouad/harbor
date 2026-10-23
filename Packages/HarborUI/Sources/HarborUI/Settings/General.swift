// Licensed under GPL-3.0. See LICENSE.
//
//  General.swift
//  Harbor
//
//  Created by Maciek Bagiński on 07/12/2025.
//

import SwiftUI
import HarborDesign
import HarborSettings
import HarborWeb
#if os(macOS)
import AppKit
import ApplicationServices
#endif

public struct SettingsGeneralTab: View {
    @Environment(TabsController.self) private var tabs
    @Environment(HarborSettingsService.self) var harborSettings
    @State private var showingAddSite = false
    @State private var showingAddEngine = false
    #if os(macOS)
    @State private var hasAccessibility = AXIsProcessTrusted()
    #endif

    public init() {}

    /// The provider list, shared by both platforms' spellings of the row.
    @ViewBuilder
    private func searchEnginePicker(_ settings: HarborSettingsService) -> some View {
        @Bindable var settings = settings
        Picker("Default search engine", selection: $settings.searchEngineId) {
            ForEach(SearchProvider.allCases) { provider in
                Text(provider.displayName).tag(provider.rawValue)
            }
            ForEach(harborSettings.customSearchEngines) { engine in
                Text(engine.name).tag(engine.id.uuidString)
            }
        }
    }

    public var body: some View {
        @Bindable var settings = harborSettings
        Form {
            #if os(macOS)
            // Quitting and Sparkle updates are both macOS-only concepts.
            Section {
                Toggle("Warn before quitting Harbor", isOn: $settings.askBeforeQuit)
                Toggle("Automatically update Harbor", isOn: .constant(true))
                    .disabled(true)
            }

            Section {
                Toggle("Automatic Picture in Picture", isOn: $settings.autoPictureInPicture)
                Toggle("Pinch the floating player over other apps", isOn: $settings.pipPinchOverOtherApps)
                    .onChange(of: settings.pipPinchOverOtherApps) { _, on in
                        guard on else { return }
                        // macOS shows its own prompt the first time.
                        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                        hasAccessibility = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
                    }
                if settings.pipPinchOverOtherApps && !hasAccessibility {
                    LabeledContent("Accessibility access is off") {
                        Button("Open Accessibility Settings…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            } footer: {
                Text("Leaving a tab with a playing video keeps it playing in a small player above the sidebar, or in a floating window when the sidebar is hidden. Move the floating player with two fingers and pinch to resize it. While another app is in front, macOS sends a pinch only to that app, so pinching the player there needs Accessibility access. Harbor then takes only pinches made with the pointer on the player.")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                hasAccessibility = AXIsProcessTrusted()
            }
            #endif

            Section {
                Picker("Tab Management", selection: Binding(
                    get: { harborSettings.tabManagementMode },
                    set: { harborSettings.tabManagementMode = $0 }
                )) {
                    ForEach(TabManagementMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Picker("On Startup", selection: Binding(
                    get: { harborSettings.startupLoadMode },
                    set: { harborSettings.startupLoadMode = $0 }
                )) {
                    ForEach(StartupLoadMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Button("Unload All Inactive Tabs") {
                    tabs.unloadAllHidden()
                }
            } header: {
                Text("Performance")
            } footer: {
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
                    Label(
                        harborSettings.tabManagementMode.description,
                        systemImage: harborSettings.tabManagementMode.icon
                    )
                    Label(harborSettings.startupLoadMode.description, systemImage: "power")
                }
            }

            Section {
                #if os(macOS)
                LabeledContent("Default search engine") {
                    HStack(spacing: HarborDesign.Spacing.md) {
                        searchEnginePicker(settings)
                            .labelsHidden()

                        Button {
                            showingAddEngine = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                #else
                // A picker inside a LabeledContent's trailing slot gets squeezed
                // to "G...gle" at phone width. The Form's own picker row does not,
                // so the add button takes a row of its own.
                searchEnginePicker(settings)
                Button("Add Search Engine…") { showingAddEngine = true }
                #endif

                if let selected = harborSettings.customSearchEngines.first(where: { $0.id.uuidString == harborSettings.searchEngineId }) {
                    LabeledContent {
                        Button("Remove") {
                            harborSettings.customSearchEngines.removeAll { $0.id == selected.id }
                            harborSettings.searchEngineId = SearchProvider.google.rawValue
                        }
                        .foregroundStyle(.red)
                        .buttonStyle(.plain)
                    } label: {
                        Text(selected.name)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Search")
            }

            Section {
                ForEach(harborSettings.siteSearchEntries) { entry in
                    LabeledContent {
                        HStack(spacing: HarborDesign.Spacing.md) {
                            Text(entry.domain)
                                .foregroundStyle(.secondary)
                            Button {
                                harborSettings.siteSearchEntries.removeAll { $0.id == entry.id }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        Label {
                            Text(entry.name)
                        } icon: {
                            Circle()
                                .fill(entry.color)
                                .frame(
                                    width: HarborDesign.Size.statusDot,
                                    height: HarborDesign.Size.statusDot
                                )
                        }
                    }
                }

                Button {
                    showingAddSite = true
                } label: {
                    Label("Add Site", systemImage: "plus")
                }

                Button("Reset to Defaults") {
                    harborSettings.siteSearchEntries = SiteSearchEntry.defaultSites
                }
            } header: {
                Text("Site Search")
            } footer: {
                Text("Type a prefix in the command palette and press Tab to search a site directly.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSite) {
            SiteSearchEntryEditor(entry: nil) { newEntry in
                harborSettings.siteSearchEntries.append(newEntry)
            }
        }
        .sheet(isPresented: $showingAddEngine) {
            CustomSearchEngineEditor { newEngine in
                harborSettings.customSearchEngines.append(newEngine)
            }
        }
    }
}

// MARK: - Custom Search Engine Editor

struct CustomSearchEngineEditor: View {
    let onSave: (CustomSearchEngine) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var urlTemplate: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xl) {
            Text("Add Custom Search Engine")
                .font(HarborDesign.Font.heading)

            Form {
                Section {
                    TextField("Name (e.g. Startpage)", text: $name)
                    TextField("URL Template (use %@ for query)", text: $urlTemplate)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let engine = CustomSearchEngine(
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        urlTemplate: urlTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(engine)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || urlTemplate.isEmpty)
            }
        }
        .padding(HarborDesign.Spacing.xxl)
        .frame(width: HarborDesign.Size.sheetSmallWidth)
    }
}
