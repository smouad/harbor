// Licensed under GPL-3.0. See LICENSE.
//
//  ImportStage.swift
//  Harbor
//

import AppKit
import HarborDesign
import HarborUI
import SwiftUI

enum Browsers {
    case arc
    case chrome
    case safari
    case dia
    case firefox
    case zen

    var name: String {
        switch self {
        case .arc: return "Arc"
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        case .dia: return "Dia"
        case .firefox: return "Firefox"
        case .zen: return "Zen"
        }
    }
}

/// Nothing is chosen until the person picks a browser, so Return can never start an import.
/// Browsers found on this Mac come first, as Dia lists them.
struct ImportStage: View {
    @Binding var selectedBrowser: Browsers?
    @Binding var options: ChromiumImportOptions
    var accentHex: String

    private struct Source {
        let browser: Browsers
        let logo: String
        let bundleID: String
        let detail: String
    }

    private static let sources = [
        Source(browser: .arc, logo: "arc-logo", bundleID: "company.thebrowser.Browser", detail: "Spaces, pinned tabs, folders and favorites"),
        Source(browser: .dia, logo: "dia-logo", bundleID: "company.thebrowser.dia", detail: "Favorites and open tabs"),
        Source(browser: .safari, logo: "safari-logo", bundleID: "com.apple.Safari", detail: "Bookmarks and history"),
    ]

    var body: some View {
        OnboardingStageLayout(
            title: "Bring your tabs with you",
            message: "Import from the browser you use now. Everything is read on this Mac and stays here."
        ) {
            if selectedBrowser == .arc || selectedBrowser == .dia {
                optionsList
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                VStack(spacing: HarborDesign.Spacing.md) {
                    ForEach(Self.sortedSources, id: \.bundleID) { source in
                        row(source)
                    }
                }
                .frame(width: 340)
            }
        }
    }

    /// What to bring over besides tabs and spaces. Nothing that needs the keychain is read unless
    /// its switch is on.
    private var optionsList: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.sm) {
            Text("Also bring over")
                .font(HarborDesign.Font.body)
                .foregroundStyle(.primary)
            VStack(spacing: HarborDesign.Spacing.sm) {
                optionRow("Signed-in accounts", detail: "Stay signed in to your sites. macOS asks once.", isOn: $options.signIns)
                optionRow("History", detail: "Pages you visited", isOn: $options.history)
                optionRow("Bookmarks", detail: "Saved pages and folders", isOn: $options.bookmarks)
                optionRow("Passwords", detail: "Offered when you click a sign-in field", isOn: $options.passwords)
            }
        }
        .transition(.opacity)
    }

    private func optionRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
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
        .padding(.horizontal, HarborDesign.Spacing.lg)
        .padding(.vertical, HarborDesign.Spacing.md)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.lg).fill(HarborDesign.Surface.fill))
    }

    private static var sortedSources: [Source] {
        sources.filter { isInstalled($0) } + sources.filter { !isInstalled($0) }
    }

    private static func isInstalled(_ source: Source) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: source.bundleID) != nil
    }

    private func row(_ source: Source) -> some View {
        let isSelected = selectedBrowser == source.browser
        let shape = HarborDesign.Radius.shape(HarborDesign.Radius.lg)
        return Button {
            selectedBrowser = isSelected ? nil : source.browser
        } label: {
            HStack(spacing: HarborDesign.Spacing.lg) {
                Image(source.logo)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    Text(source.browser.name)
                        .font(HarborDesign.Font.title)
                        .foregroundStyle(HarborDesign.Brand.foam)
                    Text(Self.isInstalled(source) ? source.detail : "Not on this Mac")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(HarborDesign.Brand.foam.opacity(0.65))
                }
                Spacer(minLength: 0)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(HarborDesign.Font.titleLarge)
                    .foregroundStyle(HarborDesign.Brand.foam.opacity(isSelected ? 1 : 0.35))
            }
            .padding(HarborDesign.Spacing.lg)
            .background(shape.fill(HarborDesign.Brand.foam.opacity(isSelected ? 0.2 : 0.08)))
            .overlay(shape.strokeBorder(HarborDesign.Brand.foam.opacity(isSelected ? 0.7 : 0.12), lineWidth: isSelected ? 1.5 : 1))
            .contentShape(shape)
            .animation(HarborDesign.Motion.quick, value: isSelected)
        }
        .buttonStyle(ScaleButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
