// Licensed under GPL-3.0. See LICENSE.
//
//  FaviconPick.swift
//  Harbor
//
//  Which of a page's declared icons to try first. Pure, so `Checks/FaviconPickCheck.swift` can
//  compile it on its own.
//

import Foundation

/// One `<link rel="icon">` (or Apple touch icon) a page declares.
struct FaviconCandidate: Equatable {
    var url: URL
    /// The `sizes` attribute as written ("32x32", "any", or empty).
    var sizes: String
    var type: String
    /// The `media` attribute: sites ship a light and a dark icon and pick with it.
    var media: String
    var rel: String

    private var isDarkVariant: Bool { media.lowercased().contains("dark") }
    private var isLightVariant: Bool { media.lowercased().contains("light") }
    private var isTouchIcon: Bool { rel.lowercased().contains("apple-touch") }
    private var isVector: Bool { type.lowercased().contains("svg") || url.pathExtension.lowercased() == "svg" }

    /// The edge in points the icon declares, or a guess: a vector scales to anything, and an
    /// undeclared one is usually the old 32 pixel icon.
    private var declaredSize: Int {
        let lowered = sizes.lowercased()
        if lowered == "any" { return 64 }
        // "16x16 32x32": the biggest listed.
        let edges = lowered.split(separator: " ").compactMap { $0.split(separator: "x").first.flatMap { Int($0) } }
        if let largest = edges.max() { return largest }
        return isVector ? 64 : 32
    }

    /// Lower is better. The sidebar draws icons at 16 points, so about 64 pixels is plenty and
    /// sharp on a Retina screen; anything under 32 comes out soft, and a huge one is wasted work.
    func penalty(preferDark: Bool) -> Int {
        var score = 0
        let wrongVariant = preferDark ? isLightVariant : isDarkVariant
        if wrongVariant { score += 1000 }
        let size = declaredSize
        score += size < 32 ? 200 + (32 - size) * 4 : abs(size - 64) / 2
        // A touch icon is a full-bleed square: fine, but a site's own favicon is meant for this.
        if isTouchIcon { score += 60 }
        return score
    }
}

enum FaviconPick {
    /// Candidates in the order to try them. The same URL is tried once.
    static func order(_ candidates: [FaviconCandidate], preferDark: Bool) -> [FaviconCandidate] {
        var seen = Set<URL>()
        return candidates
            .enumerated()
            .sorted { lhs, rhs in
                let (a, b) = (lhs.element.penalty(preferDark: preferDark), rhs.element.penalty(preferDark: preferDark))
                return a == b ? lhs.offset < rhs.offset : a < b
            }
            .map(\.element)
            .filter { seen.insert($0.url).inserted }
    }
}
