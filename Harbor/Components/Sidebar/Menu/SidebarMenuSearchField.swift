// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarMenuSearchField.swift
//  Harbor
//

import SwiftUI
import HarborDesign

/// The history and downloads search field: a filled squircle the height of the sidebar's controls.
struct SidebarMenuSearchField: View {
    let prompt: LocalizedStringKey
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(HarborDesign.Font.body)
                .foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.secondary)
                .foregroundStyle(.primary)
                .focused($isFocused)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(HarborDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HarborDesign.Spacing.lg)
        .frame(height: HarborDesign.Size.chromeControl)
        .frame(maxWidth: .infinity)
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onTapGesture { isFocused = true }
        .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
    }
}
