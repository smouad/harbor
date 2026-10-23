// Licensed under GPL-3.0. See LICENSE.
//
//  GradientColorManager.swift
//  Harbor
//
//  Publishes the active space's accent color. The type name predates the
//  Phase 2 remodel; it no longer holds a gradient, only the one color
//  derived from it.
//

import AppKit
import SwiftUI
import HarborDesign

@MainActor
final class GradientColorManager: ObservableObject {
    @Published private(set) var accentColor: Color = SpaceGradient.default.primaryColor
    @Published private(set) var accentNSColor: NSColor = NSColor(SpaceGradient.default.primaryColor)

    /// The fill of a primary button. A grey accent, which a new or imported space starts with,
    /// made every primary button read as disabled, so a low-saturation accent falls back to a
    /// solid near-black (near-white in dark mode), the way Arc draws its primary buttons.
    var actionColor: Color { isNeutralAccent ? Self.neutralAction : accentColor }

    /// The label color on `actionColor` when it is the neutral fallback; nil means work it out
    /// from the accent.
    var actionForeground: Color? { isNeutralAccent ? Self.neutralActionLabel : nil }

    private var isNeutralAccent: Bool {
        (accentNSColor.usingColorSpace(.sRGB)?.saturationComponent ?? 0) < 0.2
    }

    private static let neutralAction = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.11, alpha: 1)
    })

    private static let neutralActionLabel = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .black : .white
    })

    /// Set the accent with no animation (window setup, non-active windows).
    func setImmediate(_ gradient: SpaceGradient) {
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) {
            accentColor = gradient.primaryColor
            accentNSColor = NSColor(gradient.primaryColor)
        }
    }
}
