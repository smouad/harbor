// Licensed under GPL-3.0. See LICENSE.
//
//  BlockingStage.swift
//  Harbor
//
//  Built-in blocking, shown at its real setting: on from the start, as in Arc's "No more ads or
//  trackers" and Dia's privacy step. The page on the right closes up around its ads when the
//  switch is on. SponsorBlock asks a third-party server, so it stays off until chosen.
//

import HarborDesign
import HarborUI
import SwiftUI

struct BlockingStage: View {
    var accentHex: String
    @Environment(\.harborSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingStageLayout(
            title: "Ads and trackers are blocked",
            message: "Harbor blocks them on every site from the start, with nothing to install. Pages load faster and follow you less."
        ) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.lg) {
                switchRow(
                    "Block ads and trackers",
                    detail: "On every site, in every space",
                    isOn: Binding(get: { settings.adBlockerEnabled }, set: { settings.adBlockerEnabled = $0 }))
                switchRow(
                    "Skip sponsor segments on YouTube",
                    detail: "Uses SponsorBlock's shared list",
                    isOn: Binding(get: { settings.sponsorBlockEnabled }, set: { settings.sponsorBlockEnabled = $0 }))
                Label {
                    Text("Extensions install straight from the Chrome Web Store and Firefox Add-ons.")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "puzzlepiece.extension")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, HarborDesign.Spacing.xs)
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                BlockedPagePreview(isBlocking: settings.adBlockerEnabled, isDark: colorScheme == .dark)
            }
        }
    }

    private func switchRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: HarborDesign.Spacing.lg) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(title)
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(HarborSwitchToggleStyle())
        }
        .padding(HarborDesign.Spacing.lg)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.lg).fill(HarborDesign.Surface.fill))
    }
}

/// A page with two ads in it. With blocking on, the ads fade out and the text closes up.
private struct BlockedPagePreview: View {
    var isBlocking: Bool
    var isDark: Bool

    private var ink: Color { isDark ? .white : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            HarborDesign.Radius.shape(2).fill(ink.opacity(0.2)).frame(width: 150, height: 12)
                .padding(.bottom, HarborDesign.Spacing.xs)
            if !isBlocking { ad(height: 44) }
            lines([250, 232, 244, 180])
            if !isBlocking { ad(height: 64) }
            lines([240, 210, 236, 120])
        }
        .padding(HarborDesign.Spacing.xxl)
        .frame(width: 300, height: 300, alignment: .topLeading)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.md).fill(isDark ? Color(white: 0.17) : .white))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .animation(HarborDesign.Motion.standard, value: isBlocking)
        .accessibilityHidden(true)
    }

    private func ad(height: CGFloat) -> some View {
        HarborDesign.Radius.shape(HarborDesign.Radius.sm)
            .fill(Color(hex: "#F2B84B").opacity(0.35))
            .overlay(alignment: .topLeading) {
                Text("Ad")
                    .font(HarborDesign.Font.micro)
                    .foregroundStyle(ink.opacity(0.5))
                    .padding(HarborDesign.Spacing.xs)
            }
            .frame(height: height)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
    }

    private func lines(_ widths: [CGFloat]) -> some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.sm) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                Capsule().fill(ink.opacity(0.12)).frame(width: width, height: 6)
            }
        }
    }
}
