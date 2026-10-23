// Licensed under GPL-3.0. See LICENSE.
//
//  DefaultBrowserStage.swift
//  Harbor
//

import AppKit
import HarborDesign
import SwiftUI

/// Asks once, with nothing preselected, as Arc's "Go steady" and Dia's default step do. macOS
/// shows its own confirmation after the button.
struct DefaultBrowserStage: View {
    var accentHex: String
    var addressOnTop: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingStageLayout(
            title: "Open links in Harbor?",
            message: Self.isDefault
                ? "Harbor is already your default browser. Links from other apps open here."
                : "Links from Mail, Messages and other apps will open here. macOS asks you to confirm, and you can change it in System Settings."
        ) {
            EmptyView()
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                VStack(spacing: HarborDesign.Spacing.lg) {
                    linkBubble
                    Image(systemName: "arrow.down")
                        .font(HarborDesign.Font.title)
                        .foregroundStyle(HarborDesign.Brand.foam.opacity(0.7))
                    OnboardingWindowPreview(accentHex: accentHex, addressOnTop: addressOnTop, isDark: colorScheme == .dark, width: 300)
                }
            }
        }
    }

    private var linkBubble: some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            Image(systemName: "link")
                .font(HarborDesign.Font.caption)
            Text("Here's the doc we talked about")
                .font(HarborDesign.Font.body)
                .underline()
        }
        .foregroundStyle(Color(hex: "#0A84FF"))
        .padding(.horizontal, HarborDesign.Spacing.lg)
        .padding(.vertical, HarborDesign.Spacing.md)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.xl).fill(HarborDesign.Brand.foam))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
        .accessibilityHidden(true)
    }

    /// Whether macOS already opens web links in this copy of Harbor.
    static var isDefault: Bool {
        guard let url = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: url) else { return false }
        return handler.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// Asks macOS to make Harbor the browser for web links. macOS shows its own confirmation;
    /// `completion` runs once it has answered, either way.
    static func setAsDefault(completion: @escaping () -> Void) {
        let app = Bundle.main.bundleURL
        NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http") { _ in
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https") { _ in
                DispatchQueue.main.async(execute: completion)
            }
        }
    }
}
