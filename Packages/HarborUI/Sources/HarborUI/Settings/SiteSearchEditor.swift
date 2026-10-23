// Licensed under GPL-3.0. See LICENSE.
//
//  SiteSearchEditor.swift
//  Harbor
//
//  Created by Maciek Bagiński on 03/08/2025.
//

import HarborSettings
import SwiftUI
import HarborDesign

struct SiteSearchEntryEditor: View {
    let entry: SiteSearchEntry?
    let onSave: (SiteSearchEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var domain: String = ""
    @State private var searchURLTemplate: String = ""
    @State private var colorHex: String = "#666666"

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xl) {
            Text(entry == nil ? "Add Site Search" : "Edit Site Search")
                .font(HarborDesign.Font.heading)

            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Domain (e.g. youtube.com)", text: $domain)
                    TextField("Search URL (use {query})", text: $searchURLTemplate)
                    TextField("Color Hex (e.g. #E62617)", text: $colorHex)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let saved = SiteSearchEntry(
                        id: entry?.id ?? UUID(),
                        name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                        domain: domain.trimmingCharacters(in: .whitespacesAndNewlines),
                        searchURLTemplate: searchURLTemplate.trimmingCharacters(in: .whitespacesAndNewlines),
                        colorHex: colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    onSave(saved)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || domain.isEmpty || searchURLTemplate.isEmpty)
            }
        }
        .padding(HarborDesign.Spacing.xxl)
        .frame(width: HarborDesign.Size.sheetSmallWidth)
        .onAppear {
            if let entry {
                name = entry.name
                domain = entry.domain
                searchURLTemplate = entry.searchURLTemplate
                colorHex = entry.colorHex
            }
        }
    }
}

// MARK: - Site Search Color

extension SiteSearchEntry {
    /// The swatch colour stored on the entry as a hex string.
    public var color: Color {
        Color(hex: colorHex)
    }
}
