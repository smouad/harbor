// Licensed under GPL-3.0. See LICENSE.
//
//  NavButton.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//  Updated by Aether Aurelia on 11/10/2025.
//

import SwiftUI
import HarborDesign

/// Square icon button. Hover shows a fill, press shows a stronger fill and a 0.95 scale.
/// Pass size: or radius: only where a call site needs a non-default (media controls 24, URL bar and space title 28, space switcher radius lg).
public struct HarborIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    let size: CGFloat
    let radius: CGFloat

    public init(size: CGFloat = HarborDesign.Size.iconButton, radius: CGFloat = HarborDesign.Radius.md) {
        self.size = size
        self.radius = radius
    }

    public func makeBody(configuration: Configuration) -> some View {
        ZStack {
            HarborDesign.Radius.shape(radius)
                .fill(fill(isPressed: configuration.isPressed))
                .frame(width: size, height: size)
            configuration.label
                .foregroundStyle(.primary)
        }
        .frame(width: size, height: size)
        .opacity(isEnabled ? 1.0 : 0.3)
        .contentTransition(.symbolEffect(.replace.upUp.byLayer, options: .nonRepeating))
        .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
        .animation(HarborDesign.Motion.quick, value: configuration.isPressed)
        .animation(HarborDesign.Motion.quick, value: isHovering)
        .onHoverTracking { hovering in isHovering = hovering }
    }

    private func fill(isPressed: Bool) -> Color {
        guard isEnabled else { return .clear }
        if isPressed { return HarborDesign.Surface.fillPressed }
        if isHovering { return HarborDesign.Surface.fill }
        return .clear
    }
}

/// A round icon button that always shows a soft fill, for the window's navigation controls
/// (sidebar, back, forward, reload) in the top bar and the traffic-light row.
public struct HarborCircleButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    /// What the fill is drawn from: the icon's own color over a page, `.primary` on the sidebar.
    let tint: Color

    public init(tint: Color = .primary) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(HarborDesign.Font.body)
            .foregroundStyle(tint)
            .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
            .background(Circle().fill(tint.opacity(fillOpacity(isPressed: configuration.isPressed))))
            .opacity(isEnabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.94 : 1)
            .animation(HarborDesign.Motion.quick, value: configuration.isPressed)
            .animation(HarborDesign.Motion.quick, value: isHovering)
            .onHoverTracking { hovering in isHovering = hovering }
    }

    private func fillOpacity(isPressed: Bool) -> Double {
        guard isEnabled else { return 0.05 }
        if isPressed { return 0.2 }
        return isHovering ? 0.14 : 0.08
    }
}

public extension View {
    /// Standalone icon buttons, Harbor's one button look: no container, a fill only on hover.
    func harborIconButtons() -> some View {
        labelStyle(.iconOnly)
            .buttonStyle(HarborIconButtonStyle())
            .foregroundStyle(.primary)
    }
}

/// Rectangular, labeled variant of HarborIconButtonStyle that allows custom widths
/// Use this for buttons that need to be wider than square (e.g., "New Space" button)
public struct RectNavButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.isEnabled) var isEnabled
    @Environment(\.controlSize) var controlSize
    @State private var isHovering: Bool = false

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            .background {
                HarborDesign.Radius.shape(cornerRadius)
                    .fill(.primary.opacity(backgroundColorOpacity(isPressed: configuration.isPressed)))
            }
            .contentShape(.rect)
            .opacity(isEnabled ? 1.0 : 0.3)
            .contentTransition(.symbolEffect(.replace.upUp.byLayer, options: .nonRepeating))
            .scaleEffect(configuration.isPressed && isEnabled ? 0.95 : 1.0)
            .animation(HarborDesign.Motion.quick, value: configuration.isPressed)
            .animation(HarborDesign.Motion.quick, value: isHovering)
            .onHoverTracking { hovering in
                isHovering = hovering
            }
    }

    private var height: CGFloat {
        switch controlSize {
        case .mini: 24
        case .small: 28
        case .regular: 32
        case .large: 40
        case .extraLarge: 48
        @unknown default: 32
        }
    }

    private var horizontalPadding: CGFloat {
        switch controlSize {
        case .mini: 8
        case .small: 10
        case .regular: 12
        case .large: 16
        case .extraLarge: 20
        @unknown default: 12
        }
    }

    private var cornerRadius: CGFloat {
        HarborDesign.Radius.md
    }

    private func backgroundColorOpacity(isPressed: Bool) -> Double {
        if (isHovering || isPressed) && isEnabled {
            return colorScheme == .dark ? 0.2 : 0.1
        } else {
            return 0.0
        }
    }
}

#Preview("Square Buttons") {
    VStack(spacing: 20) {
        // Default
        Button {
        } label: {
            Image(systemName: "arrow.left")
        }
        .buttonStyle(HarborIconButtonStyle())
        .foregroundStyle(Color.primary)

        // With foregroundStyle
        Button {
        } label: {
            Image(systemName: "heart.fill")
        }
        .buttonStyle(HarborIconButtonStyle())
        .foregroundStyle(.red)

        // Different sizes
        HStack {
            Button { } label: { Image(systemName: "star") }
                .buttonStyle(HarborIconButtonStyle(size: 24))
                .foregroundStyle(Color.pink)

            Button { } label: { Image(systemName: "star") }
                .buttonStyle(HarborIconButtonStyle(size: 28))
                .foregroundStyle(Color.purple)

            Button { } label: { Image(systemName: "star") }
                .buttonStyle(HarborIconButtonStyle())
                .foregroundStyle(Color.yellow)

            Button { } label: { Image(systemName: "star") }
                .buttonStyle(HarborIconButtonStyle(size: 40))
                .foregroundStyle(Color.orange)
        }

        // Disabled
        Button {
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(HarborIconButtonStyle())
        .foregroundStyle(Color.primary)
        .disabled(true)
    }
    .padding()
}

#Preview("Rectangular Buttons") {
    VStack(spacing: 20) {
        // Icon with text
        Button {
        } label: {
            Label("New Space", systemImage: "plus")
        }
        .buttonStyle(RectNavButtonStyle())
        .foregroundStyle(Color.primary)

        // Icon only (still rectangular due to padding)
        Button {
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(RectNavButtonStyle())
        .foregroundStyle(Color.primary)

        // Different sizes
        VStack(spacing: 12) {
            Button { } label: { Label("Mini", systemImage: "star") }
                .buttonStyle(RectNavButtonStyle())
                .foregroundStyle(Color.pink)
                .controlSize(.mini)

            Button { } label: { Label("Small", systemImage: "star") }
                .buttonStyle(RectNavButtonStyle())
                .foregroundStyle(Color.purple)
                .controlSize(.small)

            Button { } label: { Label("Regular", systemImage: "star") }
                .buttonStyle(RectNavButtonStyle())
                .foregroundStyle(Color.yellow)

            Button { } label: { Label("Large", systemImage: "star") }
                .buttonStyle(RectNavButtonStyle())
                .foregroundStyle(Color.orange)
                .controlSize(.large)
        }

        // Disabled
        Button {
        } label: {
            Label("Disabled", systemImage: "xmark")
        }
        .buttonStyle(RectNavButtonStyle())
        .foregroundStyle(Color.primary)
        .disabled(true)
    }
    .padding()
}
