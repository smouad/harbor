// Licensed under GPL-3.0. See LICENSE.
//
//  HelloStage.swift
//  Harbor
//
//  The first screen says what Harbor is and that there is nothing to sign in to. Arc and Dia
//  both open with an account; that was the most complained-about part of either.
//

import HarborDesign
import SwiftUI

struct HelloStage: View {
    var accentHex: String
    var addressOnTop: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingStageLayout(
            title: "Welcome to Harbor",
            message: "A calm, fast browser for your Mac, with nothing to sign in to.",
            badge: "harbor-logo-1024"
        ) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.lg) {
                fact("sidebar.left", "Tabs in a sidebar, sorted into spaces")
                fact("shield.lefthalf.filled", "Ads and trackers blocked from the start")
                fact("puzzlepiece.extension", "Extensions from Chrome and Firefox")
                fact("moon.zzz", "Idle tabs rest, so memory stays low")
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                OnboardingWindowPreview(accentHex: accentHex, addressOnTop: addressOnTop, isDark: colorScheme == .dark)
            }
        }
    }

    private func fact(_ symbol: String, _ text: String) -> some View {
        Label {
            Text(text)
                .font(HarborDesign.Font.bodyRegular)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .font(HarborDesign.Font.body)
                .foregroundStyle(Color(hex: accentHex))
                .frame(width: 20)
        }
    }
}
