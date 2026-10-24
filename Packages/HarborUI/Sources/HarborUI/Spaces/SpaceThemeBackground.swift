// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceThemeBackground.swift
//  HarborUI
//
//  The window chrome a themed space draws: its color dots blended over a base, with the space's
//  own grain on top. Static layers only, so nothing is sampled per frame.
//

import SwiftUI
import HarborDesign
import HarborTabsCore

public struct SpaceThemeBackground: View {
    let theme: SpaceTheme
    let isActive: Bool

    public init(theme: SpaceTheme, isActive: Bool) {
        self.theme = theme
        self.isActive = isActive
    }

    /// The color the dots blend into. `auto` is the plain window background, so a theme with the
    /// default mode reads like the fade it replaces.
    private var base: Color {
        switch theme.mode {
        case .auto: HarborDesign.Surface.windowBackground
        case .light: Color(white: 0.95)
        case .dark: Color(white: 0.11)
        }
    }

    public var body: some View {
        GeometryReader { proxy in
            let reach = max(proxy.size.width, proxy.size.height) * 0.9
            ZStack {
                base
                ZStack {
                    ForEach(theme.dots) { dot in
                        let color = Color(hex: dot.hex)
                        RadialGradient(
                            colors: [color, color.opacity(0)],
                            center: UnitPoint(x: dot.x, y: dot.y),
                            startRadius: 0,
                            endRadius: reach
                        )
                    }
                }
                // An inactive window dims, as the plain fade does.
                .opacity(theme.intensity * (isActive ? 1 : 0.6))
                HarborGrain(strength: theme.grain * 2)
            }
        }
    }
}
