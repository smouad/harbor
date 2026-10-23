// Licensed under GPL-3.0. See LICENSE.
//
//  FInalStage.swift
//  Harbor
//
//  The basics, as Arc's first window lists them: the keys worth learning first and the two
//  things Harbor does on its own, Peek and resting tabs.
//

import HarborDesign
import SwiftUI

struct FinalStage: View {
    var accentHex: String
    @Environment(\.harborSettings) private var settings

    var body: some View {
        OnboardingStageLayout(
            title: "You're ready",
            message: "A few things worth knowing. Every shortcut is in Settings, under Shortcuts."
        ) {
            EmptyView()
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                VStack(spacing: HarborDesign.Spacing.sm) {
                    tip(keys: "⌘T", text: "Open a site, search, or jump to a tab")
                    tip(keys: "⌥ Click", text: "Peek at a link without leaving the page")
                    tip(keys: "⌘S", text: "Show or hide the sidebar")
                    tip(keys: "⌥⌘T", text: "Move the address bar")
                    tip(keys: "⌃⌘]", text: "Go to the next space")
                    tip(symbol: "moon.zzz", text: "Tabs you leave alone rest after \(restDelay) and come back where you left them")
                }
                .frame(width: 380)
            }
        }
    }

    private var restDelay: String {
        let seconds = Int(settings.tabManagementMode.unloadTimeout)
        return seconds >= 3600 ? "\(seconds / 3600) hours" : "\(seconds / 60) minutes"
    }

    private func tip(keys: String? = nil, symbol: String? = nil, text: String) -> some View {
        HStack(spacing: HarborDesign.Spacing.lg) {
            Text(text)
                .font(HarborDesign.Font.body)
                .foregroundStyle(HarborDesign.Brand.foam.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Group {
                if let keys {
                    Text(keys)
                } else if let symbol {
                    Image(systemName: symbol)
                }
            }
            .font(HarborDesign.Font.title)
            .foregroundStyle(HarborDesign.Brand.foam)
            .padding(.horizontal, HarborDesign.Spacing.md)
            .padding(.vertical, HarborDesign.Spacing.xs)
            .background(HarborDesign.Radius.shape(HarborDesign.Radius.sm).fill(HarborDesign.Brand.foam.opacity(0.12)))
        }
        .padding(.horizontal, HarborDesign.Spacing.lg)
        .padding(.vertical, HarborDesign.Spacing.md)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.lg).fill(HarborDesign.Brand.foam.opacity(0.07)))
    }
}
