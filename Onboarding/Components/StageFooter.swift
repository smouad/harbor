// Licensed under GPL-3.0. See LICENSE.
//
//  StageFooter.swift
//  Harbor
//
//  One main button in the space's color, with the Return glyph since Return presses it, and a
//  quiet text button beside it when the step can be passed over.
//

import HarborDesign
import SwiftUI

struct StageFooter: View {
    var primaryTitle: String
    var accentHex: String
    var isPrimaryEnabled: Bool = true
    var isLoading: Bool = false
    var secondaryTitle: String? = nil
    var onPrimary: () -> Void
    var onSecondary: () -> Void = {}

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.xl) {
            Button(action: onPrimary) {
                HStack(spacing: HarborDesign.Spacing.sm) {
                    Text(primaryTitle)
                        .font(HarborDesign.Font.title)
                        .contentTransition(.opacity)
                    if isLoading {
                        RoundedSpinner()
                            .frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "return")
                            .font(HarborDesign.Font.captionStrong)
                            .opacity(0.7)
                    }
                }
                .foregroundStyle(.white)
                .padding(.vertical, HarborDesign.Spacing.lg)
                .padding(.horizontal, HarborDesign.Spacing.xxl)
                .background(Capsule().fill(Color(hex: accentHex)))
                .contentShape(Capsule())
            }
            .buttonStyle(ScaleButtonStyle())
            .disabled(!isPrimaryEnabled || isLoading)
            .opacity(isPrimaryEnabled ? 1 : 0.4)
            .animation(HarborDesign.Motion.quick, value: isPrimaryEnabled)
            .animation(HarborDesign.Motion.standard, value: accentHex)

            if let secondaryTitle {
                Button(secondaryTitle, action: onSecondary)
                    .buttonStyle(.plain)
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.secondary)
                    .disabled(isLoading)
            }
        }
        .frame(height: OnboardingMetrics.footerHeight)
    }
}
