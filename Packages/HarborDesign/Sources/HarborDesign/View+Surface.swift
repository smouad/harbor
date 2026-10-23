// Licensed under GPL-3.0. See LICENSE.
//
//  View+Surface.swift
//  Harbor
//
//  The surface recipes every layer goes through. Harbor draws no Liquid Glass: floating layers
//  are solid cards, sidebar chrome and rows are Surface fills.
//

import SwiftUI

public extension View {
    /// A layer that floats over content: solid raised card, hairline edge, floating shadow.
    func harborFloatingSurface<S: InsettableShape>(in shape: S) -> some View {
        self.clipShape(shape)
            .background(shape.fill(HarborDesign.Surface.raised))
            .overlay(shape.strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth))
            .harborElevation(.floating)
    }

    /// Controls over video: a dark scrim, whatever the page or appearance.
    func harborMediaControl<S: Shape>(in shape: S) -> some View {
        background(shape.fill(HarborDesign.Surface.mediaScrim))
    }

    /// The selected sidebar row or pinned tile. Branch-free so view identity is stable and the
    /// change animates; the row applies its own `.raised` elevation.
    func harborRowSelection(_ isSelected: Bool, radius: CGFloat = HarborDesign.Radius.md) -> some View {
        let shape = HarborDesign.Radius.shape(radius)
        return background(shape.fill(isSelected ? HarborDesign.Surface.raised : .clear))
            .overlay(shape.strokeBorder(HarborDesign.Surface.hairline.opacity(isSelected ? 1 : 0), lineWidth: HarborDesign.Size.hairlineWidth))
    }

    /// A sidebar chrome control or group: history, sidebar and AI toggles, bottom bar buttons,
    /// search fields, filter chips. `tint` marks the chosen one of a set.
    func harborControlSurface<S: InsettableShape>(_ isOn: Bool = true, tint: Color? = nil, in shape: S) -> some View {
        background(shape.fill(isOn ? (tint?.opacity(HarborDesign.Surface.tintOpacity) ?? HarborDesign.Surface.fill) : .clear))
    }
}

/// Film grain over the window chrome, the texture Arc lays over its sidebar. The noise is drawn
/// once into a 256 px tile and repeated, so it is one static layer with no per-frame work. Light
/// and dark specks at random strength read as grain on any accent and in either appearance.
public struct HarborGrain: View {
    public init() {}

    public var body: some View {
        if let tile = Self.tile {
            Image(decorative: tile, scale: 2)
                .resizable(resizingMode: .tile)
                .opacity(HarborDesign.Surface.grainOpacity)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static let tile: CGImage? = {
        let side = 256
        // Gray plus premultiplied alpha, two bytes a pixel. A fixed seed keeps the grain the same
        // on every launch.
        var pixels = [UInt8](repeating: 0, count: side * side * 2)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in 0..<(side * side) {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let alpha = UInt8(truncatingIfNeeded: seed >> 33)
            let isLight = (seed >> 62) & 1 == 1
            pixels[index * 2] = isLight ? alpha : 0
            pixels[index * 2 + 1] = alpha
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 16, bytesPerRow: side * 2,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}
