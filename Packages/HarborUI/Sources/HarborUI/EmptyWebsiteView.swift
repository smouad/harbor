// Licensed under GPL-3.0. See LICENSE.
//
//  EmptyWebsiteView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 28/07/2025.
//

import SwiftUI
import HarborDesign
import HarborWeb

public struct EmptyWebsiteView: View {
    @Environment(\.colorScheme) var colorScheme
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(WindowRegistry.self) var windowRegistry
    @Environment(\.tabActions) private var actions

    public init() {}

    public var body: some View {
        GeometryReader { proxy in
            ZStack {
                // Match the container background so this reads as chrome, not webview content.
                let accent = windowState.isIncognito ? HarborDesign.Surface.incognitoAccent : (actions?.accentColor ?? .accentColor)
                let isActive = windowRegistry.activeWindowId == windowState.id

                HarborDesign.Surface.containerGradient(accent: accent, isActive: isActive)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
                    .harborElevation(.raised)
                    .animation(HarborDesign.Motion.standard, value: isActive)

                VStack(spacing: 16) {
                    Image(systemName: "moon.stars")
                        .font(HarborDesign.Font.display)
                        .blendMode(.overlay)

                    Text("Ah, peace.")
                        .font(HarborDesign.Font.title)
                        .foregroundColor(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
