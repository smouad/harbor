// Licensed under GPL-3.0. See LICENSE.
//
//  LayoutStage.swift
//  Harbor
//
//  Where the address bar sits, as Dia asks with its "Top of Window" and "Sidebar" tiles. The
//  preview moves the bar as the choice changes, and ⌥⌘T switches it later.
//

import HarborDesign
import SwiftUI

struct LayoutStage: View {
    var accentHex: String
    @Environment(\.harborSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingStageLayout(
            title: "Where should the address bar go?",
            message: "Above the page, where it tucks away as you scroll, or at the top of the sidebar. Switch any time with ⌥⌘T."
        ) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
                option(onTop: true, title: "Above the page", detail: "More room for the sidebar", symbol: "rectangle.topthird.inset.filled")
                option(onTop: false, title: "In the sidebar", detail: "Everything in one column", symbol: "sidebar.left")
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                OnboardingWindowPreview(accentHex: accentHex, addressOnTop: settings.topBarAddressView, isDark: colorScheme == .dark)
            }
        }
    }

    private func option(onTop: Bool, title: String, detail: String, symbol: String) -> some View {
        let isSelected = settings.topBarAddressView == onTop
        let shape = HarborDesign.Radius.shape(HarborDesign.Radius.lg)
        return Button {
            withAnimation(HarborDesign.Motion.standard) { settings.topBarAddressView = onTop }
        } label: {
            HStack(spacing: HarborDesign.Spacing.lg) {
                Image(systemName: symbol)
                    .font(HarborDesign.Font.titleLarge)
                    .foregroundStyle(isSelected ? Color(hex: accentHex) : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    Text(title)
                        .font(HarborDesign.Font.title)
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(HarborDesign.Font.titleLarge)
                    .foregroundStyle(isSelected ? Color(hex: accentHex) : Color.secondary.opacity(0.5))
            }
            .padding(HarborDesign.Spacing.lg)
            .background(shape.fill(isSelected ? HarborDesign.Surface.fill : .clear))
            .overlay(shape.strokeBorder(isSelected ? Color(hex: accentHex) : HarborDesign.Surface.hairline, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
            .animation(HarborDesign.Motion.quick, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
