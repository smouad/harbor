// Licensed under GPL-3.0. See LICENSE.
//
//  PageElsewhereView.swift
//  Harbor
//
//  Shown in place of a page whose live view another window holds.
//

import AppKit
import SwiftUI
import HarborDesign

struct PageElsewhereView: View {
    let title: String
    let onShowHere: () -> Void
    let onGoToWindow: () -> Void

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            VStack(spacing: HarborDesign.Spacing.md) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(HarborDesign.Font.display)
                    .foregroundStyle(.tertiary)
                Text("Open in another window")
                    .font(HarborDesign.Font.title)
                    .foregroundStyle(.secondary)
                if !title.isEmpty {
                    Text(title)
                        .font(HarborDesign.Font.body)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                HStack(spacing: HarborDesign.Spacing.sm) {
                    Button("Move Here", action: onShowHere)
                        .buttonStyle(.borderedProminent)
                    Button("Go to Window", action: onGoToWindow)
                        .buttonStyle(.bordered)
                }
                .controlSize(.large)
            }
            .padding(HarborDesign.Spacing.lg)
        }
    }
}

/// AppKit host for the compositor, tagged with the item it stands in for so a rebuild can
/// keep the same view instead of recreating it.
final class PageElsewhereHostView: NSHostingView<PageElsewhereView> {
    let itemID: UUID

    init(itemID: UUID, rootView: PageElsewhereView) {
        self.itemID = itemID
        super.init(rootView: rootView)
    }

    @MainActor required init(rootView: PageElsewhereView) {
        fatalError("init(rootView:) is not used")
    }

    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }
}
