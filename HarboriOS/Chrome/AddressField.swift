// Licensed under GPL-3.0. See LICENSE.
//
//  AddressField.swift
//  HarboriOS
//
//  The URL field alone. It shows the host centred while idle and the full URL
//  left-aligned while editing, the way every phone browser does, so the bar
//  stays readable at thumb distance.
//

import SwiftUI
import HarborDesign
import HarborWeb

struct AddressField: View {
    let session: PageSession?
    @Binding var text: String
    @FocusState.Binding var isFocused: Bool
    let onSubmit: () -> Void

    /// What the field shows when it is not being edited.
    private var idleText: String {
        guard let url = session?.url else { return "" }
        return url.host() ?? url.absoluteString
    }

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.xs) {
            TextField("Search or enter address", text: $text)
                .focused($isFocused)
                .keyboardType(.webSearch)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .onSubmit(onSubmit)
                .multilineTextAlignment(isFocused ? .leading : .center)
                .foregroundStyle(.primary)

            if !isFocused, let session {
                Button {
                    if session.isLoading {
                        session.stop()
                    } else {
                        session.refresh()
                    }
                } label: {
                    Image(systemName: session.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(width: HarborDesign.Size.rowButton)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, HarborDesign.Spacing.rowPadding)
        .frame(height: HarborDesign.Size.row)
        .background(HarborDesign.Surface.fill, in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onChange(of: isFocused) { _, focused in
            // Editing starts on the whole URL and ends back on the host.
            text = focused ? (session?.url.absoluteString ?? "") : idleText
        }
        .onChange(of: session?.url) { _, _ in
            guard !isFocused else { return }
            text = idleText
        }
        .onAppear { text = idleText }
    }
}
