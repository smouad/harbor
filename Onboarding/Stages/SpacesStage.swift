// Licensed under GPL-3.0. See LICENSE.
//
//  SpacesStage.swift
//  Harbor
//
//  Each space gets its color here, and the whole screen takes it on as it is picked, the way
//  Arc's theme step re-tints its window. Spaces are also where logins are kept apart, so this
//  is the step that says so.
//

import HarborDesign
import HarborSettings
import HarborTabsCore
import HarborUI
import HarborWeb
import SwiftUI

struct SpacesStage: View {
    @Binding var accentHex: String
    @Environment(TabsController.self) private var tabs
    @Environment(\.harborSettings) private var settings
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedSpaceID: UUID?

    /// The grey a starter space is created with; the step gives it a real color.
    private static let starterAccent = "#7C7C7C"

    private var spaces: [SpaceRecord] {
        tabs.orderedSpaces.filter { $0.id != tabs.agentSpaceID }
    }

    var body: some View {
        OnboardingStageLayout(
            title: "Each space keeps to itself",
            message: "A space has its own color, tabs and logins. Sign in to work sites in one space and they stay out of the others."
        ) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
                ForEach(spaces.prefix(6)) { space in
                    spaceRow(space)
                }
                if spaces.count == 1 {
                    Button("Add a Work space", systemImage: "plus", action: addWorkSpace)
                        .buttonStyle(.plain)
                        .font(HarborDesign.Font.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, HarborDesign.Spacing.rowPadding)
                        .frame(height: HarborDesign.Size.row)
                }
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                VStack(spacing: HarborDesign.Spacing.xxxl) {
                    OnboardingWindowPreview(accentHex: accentHex, addressOnTop: settings.topBarAddressView, isDark: colorScheme == .dark)
                    swatches
                    appearancePicker
                }
            }
        }
        .onAppear(perform: selectFirstSpace)
    }

    // MARK: - Spaces

    private func spaceRow(_ space: SpaceRecord) -> some View {
        let isSelected = space.id == selectedSpaceID
        return Button {
            selectedSpaceID = space.id
            accentHex = space.accentHex
        } label: {
            HStack(spacing: HarborDesign.Spacing.md) {
                Circle()
                    .fill(Color(hex: space.accentHex))
                    .frame(width: 12, height: 12)
                Text(space.name)
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(height: HarborDesign.Size.row)
            .background(
                HarborDesign.Radius.shape(HarborDesign.Radius.md)
                    .fill(isSelected ? HarborDesign.Surface.fill : .clear)
            )
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectFirstSpace() {
        guard let first = spaces.first else { return }
        let space = spaces.first { $0.id == selectedSpaceID } ?? first
        selectedSpaceID = space.id
        if space.accentHex.caseInsensitiveCompare(Self.starterAccent) == .orderedSame {
            tabs.updateSpace(space.id, name: nil, icon: nil, accentHex: accentHex)
        } else {
            accentHex = space.accentHex
        }
    }

    private func addWorkSpace() {
        let used = Set(spaces.map { $0.accentHex.uppercased() })
        let color = SpaceAccent.presets.first { !used.contains($0.hex.uppercased()) }?.hex ?? SpaceAccent.defaultHex
        guard let spaceID = tabs.createSpace(name: "Work", icon: "briefcase", accentHex: color, after: spaces.last?.id) else { return }
        selectedSpaceID = spaceID
        accentHex = color
    }

    // MARK: - Color and appearance

    private var swatches: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            ForEach(SpaceAccent.presets, id: \.hex) { preset in
                let isSelected = preset.hex.caseInsensitiveCompare(accentHex) == .orderedSame
                Button {
                    accentHex = preset.hex
                    if let selectedSpaceID {
                        tabs.updateSpace(selectedSpaceID, name: nil, icon: nil, accentHex: preset.hex)
                    }
                } label: {
                    Circle()
                        .fill(Color(hex: preset.hex))
                        .frame(width: 22, height: 22)
                        .padding(3)
                        .overlay(Circle().strokeBorder(HarborDesign.Brand.foam.opacity(isSelected ? 0.95 : 0), lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(ScaleButtonStyle())
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }

    private var appearancePicker: some View {
        HStack(spacing: HarborDesign.Spacing.xxs) {
            ForEach([AppearanceMode.light, .dark, .system], id: \.self) { mode in
                let isSelected = settings.appearanceMode == mode
                Button {
                    settings.appearanceMode = mode
                } label: {
                    Label(mode.displayName, systemImage: icon(for: mode))
                        .font(HarborDesign.Font.body)
                        .foregroundStyle(isSelected ? HarborDesign.Brand.deepNavy : HarborDesign.Brand.foam.opacity(0.85))
                        .padding(.horizontal, HarborDesign.Spacing.lg)
                        .frame(height: 28)
                        .background(Capsule().fill(HarborDesign.Brand.foam.opacity(isSelected ? 0.92 : 0)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(HarborDesign.Spacing.xxs)
        .background(Capsule().fill(HarborDesign.Brand.foam.opacity(0.1)))
        .animation(HarborDesign.Motion.quick, value: settings.appearanceMode)
    }

    private func icon(for mode: AppearanceMode) -> String {
        switch mode {
        case .light: return "sun.max"
        case .dark: return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }
}
