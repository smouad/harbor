// Licensed under GPL-3.0. See LICENSE.
//
//  AirTrafficControlSettingsView.swift
//  Harbor
//

import HarborSettings
import HarborTabsCore
import SwiftUI
import HarborDesign
import HarborTweaks
import HarborWeb

public struct AirTrafficControlSettingsView: View {
    @Environment(HarborSettingsService.self) var harborSettings
    @Environment(TabsController.self) private var tabs
    @Environment(\.siteRouting) private var siteRouting

    @State private var showingAddSheet = false
    @State private var editingRule: SiteRoutingRule?

    public init() {}

    public var body: some View {
        Form {
            Section {
                if harborSettings.siteRoutingRules.isEmpty {
                    Text("No routing rules configured.")
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(harborSettings.siteRoutingRules) { rule in
                        ruleRow(rule)
                    }
                }
            } header: {
                Text("Rules")
            } footer: {
                Text("Automatically route websites to specific spaces. When you navigate to a matching domain, a new tab opens in the designated space.")
            }

            Section {
                HStack {
                    Button {
                        showingAddSheet = true
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAddSheet) {
            RuleEditSheet(
                spaces: tabs.orderedSpaces.filter { !$0.isAgent },
                rules: harborSettings.siteRoutingRules,
                onSave: { rule in
                    siteRouting?.addRule(rule)
                }
            )
        }
        .sheet(item: $editingRule) { rule in
            RuleEditSheet(
                spaces: tabs.orderedSpaces.filter { !$0.isAgent },
                rules: harborSettings.siteRoutingRules,
                existingRule: rule,
                onSave: { updated in
                    siteRouting?.updateRule(updated)
                }
            )
        }
    }

    private func ruleRow(_ rule: SiteRoutingRule) -> some View {
        let space = tabs.space(rule.targetSpaceId)

        return LabeledContent {
            HStack(spacing: HarborDesign.Spacing.md) {
                Toggle("Enabled", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { newValue in
                        var updated = rule
                        updated.isEnabled = newValue
                        siteRouting?.updateRule(updated)
                    }
                ))
                .toggleStyle(.switch)
                .labelsHidden()

                Button {
                    siteRouting?.deleteRule(id: rule.id)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
        } label: {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                HStack(spacing: HarborDesign.Spacing.xs) {
                    Text(rule.domain)
                    if let pp = rule.pathPrefix, !pp.isEmpty {
                        Text(pp)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: HarborDesign.Spacing.xs) {
                    if let space {
                        // Spaces have no icon; the sidebar identifies them by an
                        // accent dot, so this picker uses the same mark.
                        Circle()
                            .fill(space.accentColor)
                            .frame(width: HarborDesign.Spacing.md, height: HarborDesign.Spacing.md)
                        Text(space.name)
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Space deleted")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            editingRule = rule
        }
    }

}

// MARK: - Add/Edit Sheet

private struct RuleEditSheet: View {
    let spaces: [SpaceRecord]
    /// Passed in rather than read from the environment: this is a sheet.
    let rules: [SiteRoutingRule]
    var existingRule: SiteRoutingRule?
    let onSave: (SiteRoutingRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var domain: String = ""
    @State private var pathPrefix: String = ""
    @State private var selectedSpaceId: UUID?
    @State private var isEnabled: Bool = true
    @State private var validationError: String?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Website") {
                    TextField("Domain (e.g. github.com)", text: $domain)
                        .textFieldStyle(.roundedBorder)
                    TextField("Path prefix (optional, e.g. /myorg)", text: $pathPrefix)
                        .textFieldStyle(.roundedBorder)
                }

                Section("Destination") {
                    Picker("Space", selection: $selectedSpaceId) {
                        Text("Select a space").tag(nil as UUID?)
                        ForEach(spaces) { space in
                            Text(space.name)
                                .tag(space.id as UUID?)
                        }
                    }
                }

                Section {
                    Toggle("Enabled", isOn: $isEnabled)
                }

                if let error = validationError {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                            .font(HarborDesign.Font.caption)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(existingRule != nil ? "Save" : "Add Rule") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty || selectedSpaceId == nil)
            }
            .padding(HarborDesign.Spacing.xl)
        }
        .frame(
            width: HarborDesign.Size.sheetSmallWidth,
            height: HarborDesign.Size.sheetSmallHeight
        )
        .onAppear {
            if let rule = existingRule {
                domain = rule.domain
                pathPrefix = rule.pathPrefix ?? ""
                selectedSpaceId = rule.targetSpaceId
                isEnabled = rule.isEnabled
            }
        }
    }

    private func save() {
        let normalized = SiteRoutingRule.normalizeDomain(domain)
        guard !normalized.isEmpty else {
            validationError = "Domain is required."
            return
        }

        let pp = pathPrefix.trimmingCharacters(in: .whitespaces)
        let effectivePathPrefix: String? = pp.isEmpty ? nil : pp

        let isDuplicate = rules.contains { existing in
            existing.id != existingRule?.id &&
            existing.domain == normalized &&
            existing.pathPrefix == effectivePathPrefix
        }
        if isDuplicate {
            validationError = "A rule for this domain and path already exists."
            return
        }

        guard let spaceId = selectedSpaceId else {
            validationError = "Please select a target space."
            return
        }

        let rule = SiteRoutingRule(
            id: existingRule?.id ?? UUID(),
            domain: normalized,
            pathPrefix: effectivePathPrefix,
            targetSpaceId: spaceId,
            isEnabled: isEnabled
        )
        onSave(rule)
        dismiss()
    }
}
