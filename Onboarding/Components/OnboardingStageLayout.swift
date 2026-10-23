// Licensed under GPL-3.0. See LICENSE.
//
//  OnboardingStageLayout.swift
//  Harbor
//
//  The layout every onboarding step shares, the split Arc and Dia both use: the words and the
//  step's controls on the left, a live picture of the choice on the right. `OnboardingView`
//  draws the card around it and keeps the footer in place across steps.
//

import HarborDesign
import SwiftUI

enum OnboardingMetrics {
    static let cardSize = CGSize(width: 900, height: 540)
    static let leftWidth: CGFloat = 340
    static let cardPadding: CGFloat = 40
    /// Room the left column leaves at its foot for the footer `OnboardingView` lays over it.
    static let footerHeight: CGFloat = 44
    static let backRowHeight: CGFloat = 28
}

struct OnboardingStageLayout<Controls: View, Preview: View>: View {
    let title: String
    let message: String
    /// An image drawn above the headline; the welcome step's logo.
    var badge: String? = nil
    @ViewBuilder var controls: Controls
    @ViewBuilder var preview: Preview

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxxl) {
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
                    if let badge {
                        Image(badge)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 56, height: 56)
                            .padding(.bottom, HarborDesign.Spacing.md)
                    }
                    Text(title)
                        .font(HarborDesign.Font.welcomeTitle)
                        .tracking(-0.4)
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(HarborDesign.Font.welcomeBody)
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                }
                .fixedSize(horizontal: false, vertical: true)
                controls
                Spacer(minLength: 0)
            }
            .frame(width: OnboardingMetrics.leftWidth, alignment: .leading)
            .padding(.horizontal, OnboardingMetrics.cardPadding)
            .padding(.top, OnboardingMetrics.cardPadding + OnboardingMetrics.backRowHeight)
            .padding(.bottom, OnboardingMetrics.cardPadding + OnboardingMetrics.footerHeight)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// The right half of a step: the space's color fading into the backdrop, with grain, so the
/// preview sits on the same ground the browser's chrome will.
struct OnboardingPreviewPanel<Content: View>: View {
    var accentHex: String
    @ViewBuilder var content: Content

    var body: some View {
        let shape = HarborDesign.Radius.shape(HarborDesign.Radius.lg)
        ZStack {
            LinearGradient(
                colors: [Color(hex: accentHex).mix(with: HarborDesign.Brand.deepNavy, by: 0.25),
                         Color(hex: accentHex).mix(with: HarborDesign.Brand.deepNavy, by: 0.7)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            HarborGrain()
            content
        }
        .clipShape(shape)
        .padding(HarborDesign.Spacing.lg)
        .animation(HarborDesign.Motion.standard, value: accentHex)
    }
}
