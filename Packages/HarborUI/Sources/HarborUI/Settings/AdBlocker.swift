// Licensed under GPL-3.0. See LICENSE.
//
//  AdBlocker.swift
//  Harbor
//
//  Created by Claude on 26/03/2026.
//

import SwiftUI

import HarborBlocker
import HarborDesign
import HarborSettings

public struct SettingsAdBlockerTab: View {
    @Environment(HarborSettingsService.self) var harborSettings
    @Environment(\.contentBlocker) private var contentBlocker
    @State private var isUpdatingFilters = false

    public init() {}

    public var body: some View {
        @Bindable var settings = harborSettings
        Form {
            Section {
                Toggle("Ad & Tracker Blocker", isOn: $settings.adBlockerEnabled)
                    .onChange(of: harborSettings.adBlockerEnabled) { _, enabled in
                        contentBlocker?.setEnabled(enabled)
                    }
            } footer: {
                Text("Filter lists update automatically every 24 hours.")
            }

            if harborSettings.adBlockerEnabled {
                Section("Status") {
                    HStack {
                        if isUpdatingFilters {
                            ProgressView()
                                .controlSize(.small)
                            Text("Updating filter lists...")
                                .foregroundStyle(.secondary)
                        } else {
                            if let lastUpdate = harborSettings.adBlockerLastUpdate {
                                Text("Last updated: \(lastUpdate, style: .relative) ago")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Update Filters") {
                                isUpdatingFilters = true
                                Task {
                                    await contentBlocker?.recompileFilterLists()
                                    isUpdatingFilters = false
                                }
                            }
                        }
                    }
                }

                Section("Default Filter Lists") {
                    ForEach(FilterListManager.defaultLists, id: \.filename) { list in
                        LabeledContent {
                            Text(list.category.rawValue)
                                .font(HarborDesign.Font.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, HarborDesign.Spacing.sm)
                                .padding(.vertical, HarborDesign.Spacing.xxs)
                                .background(HarborDesign.Surface.fill)
                                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
                        } label: {
                            Label {
                                Text(list.name)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                if !FilterListManager.optionalLists.isEmpty {
                    ForEach(FilterListManager.FilterListCategory.allCases, id: \.rawValue) { category in
                        let listsInCategory = FilterListManager.optionalLists.filter { $0.category == category }
                        if !listsInCategory.isEmpty {
                            Section(category.rawValue) {
                                ForEach(listsInCategory, id: \.filename) { list in
                                    Toggle(list.name, isOn: Binding(
                                        get: { harborSettings.enabledOptionalFilterLists.contains(list.filename) },
                                        set: { enabled in
                                            if enabled {
                                                harborSettings.enabledOptionalFilterLists.append(list.filename)
                                            } else {
                                                harborSettings.enabledOptionalFilterLists.removeAll { $0 == list.filename }
                                            }
                                            contentBlocker?.filterListManager.enabledOptionalFilterListFilenames = Set(harborSettings.enabledOptionalFilterLists)
                                            Task {
                                                await contentBlocker?.recompileFilterLists()
                                            }
                                        }
                                    ))
                                }
                            }
                        }
                    }

                    Section {
                        Text("Enabling additional lists improves blocking but increases memory usage.")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
