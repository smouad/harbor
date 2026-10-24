// Licensed under GPL-3.0. See LICENSE.
//
//  SpaceThemeEditor.swift
//  HarborUI
//
//  Edit Theme Color: place color dots on a canvas, pick their colors, and set the grain and
//  intensity. Every change writes through `theme`, so the window behind it updates as you drag.
//

import SwiftUI
import HarborDesign
import HarborTabsCore

public struct SpaceThemeEditor: View {
    @Binding var theme: SpaceTheme
    let onReset: () -> Void

    @State private var selectedID: UUID?
    /// The dot being dragged and how far off its middle it was taken hold of.
    @State private var grab: (id: UUID, offset: CGSize)?

    private let canvasSize = CGSize(width: SpaceTheme.canvasWidth, height: SpaceTheme.canvasHeight)
    private let dotSize: CGFloat = 18
    private let selectedDotSize: CGFloat = 26
    private let swatchSize: CGFloat = 18
    @State private var swatchPage = 0

    /// A swatch is a place on the wheel, or a neutral the wheel cannot reach.
    private enum Swatch {
        case wheel(angle: Double, radius: Double)
        /// A gray, 0 (black) to 1 (white): it sits on the map's rim, where the grays are.
        case gray(Double)

        var hex: String {
            switch self {
            case let .wheel(angle, radius): SpaceTheme.hex(angle: angle, radius: radius)
            case let .gray(level): SpaceTheme.grayHex(level)
            }
        }
    }

    /// Pages of nine, turned with the arrows beside them: the plain colors, then the same hues
    /// full strength, then soft, then the grays from white to near black.
    private let swatchPages: [[Swatch]] = [
        [.gray(1)] + [335, 285, 5, 28, 50, 130, 185, 235].map { .wheel(angle: $0, radius: 0.5) },
        [0, 25, 50, 90, 130, 170, 200, 240, 285].map { .wheel(angle: $0, radius: 0.12) },
        [340, 310, 280, 250, 215, 185, 150, 100, 45].map { .wheel(angle: $0, radius: 0.7) },
        [1.0, 0.9, 0.78, 0.66, 0.54, 0.42, 0.3, 0.18, 0.08].map { .gray($0) },
    ]

    public init(theme: Binding<SpaceTheme>, onReset: @escaping () -> Void) {
        self._theme = theme
        self.onReset = onReset
    }

    private var isLight: Bool { theme.mode == .light }

    private var selectedIndex: Int {
        theme.dots.firstIndex { $0.id == selectedID } ?? 0
    }

    public var body: some View {
        VStack(spacing: HarborDesign.Spacing.lg) {
            modeRow
            canvas
            swatchRow
            HStack(spacing: HarborDesign.Spacing.lg) {
                WavySlider(value: $theme.grain)
                IntensityDial(value: $theme.intensity)
            }
        }
        .padding(HarborDesign.Spacing.lg)
        .background(Color(white: isLight ? 0.93 : 0.11))
        // Light mode lights the whole card, as the window behind it turns light.
        .environment(\.colorScheme, isLight ? .light : .dark)
        .onAppear { selectedID = theme.dots.first?.id }
    }

    // MARK: - Mode

    private var modeRow: some View {
        HStack(spacing: HarborDesign.Spacing.xs) {
            modeButton(.auto, "sparkles", "Automatic")
            modeButton(.light, "sun.max", "Light")
            modeButton(.dark, "moon", "Dark")
            Spacer()
            Button(action: onReset) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset Theme")
        }
    }

    private func modeButton(_ mode: SpaceTheme.Mode, _ symbol: String, _ label: String) -> some View {
        Button {
            theme.mode = mode
        } label: {
            Image(systemName: symbol)
                .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                .background(HarborDesign.Radius.shape(HarborDesign.Radius.md)
                    .fill(theme.mode == mode ? HarborDesign.Surface.fillPressed : .clear))
                .foregroundStyle(theme.mode == mode ? .primary : .secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
    }

    // MARK: - Canvas

    private var canvas: some View {
        ZStack {
            // The canvas shows the colors the window is wearing.
            Color(white: isLight ? 0.9 : 0.08)
            SpaceThemeBackground(theme: theme, isActive: true).opacity(0.55)
            dotGrid
            dots
                .contentShape(Rectangle())
                .gesture(dragGesture)
            // Outside the drag, or a press on a button would first grab the nearest dot.
            countButtons
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
    }

    private var dots: some View {
        ZStack {
            Color.clear
            ForEach(theme.dots) { dot in
                let isSelected = dot.id == (selectedID ?? theme.dots.first?.id)
                Circle()
                    .fill(Color(hex: dot.hex))
                    .frame(width: isSelected ? selectedDotSize : dotSize, height: isSelected ? selectedDotSize : dotSize)
                    .overlay(Circle().strokeBorder(.white, lineWidth: isSelected ? 2 : 1).opacity(isSelected ? 1 : 0.7))
                    .position(x: dot.x * canvasSize.width, y: dot.y * canvasSize.height)
                    .animation(HarborDesign.Motion.quick, value: isSelected)
            }
        }
    }

    private var countButtons: some View {
        HStack(spacing: HarborDesign.Spacing.xl) {
            Button {
                withAnimation(HarborDesign.Motion.quick) {
                    let index = selectedIndex
                    theme.removeDot(at: index)
                    selectedID = theme.dots.first?.id
                }
            } label: {
                Image(systemName: "minus")
                    .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                    // A plain button only answers on the glyph's own pixels, and a minus has almost none.
                    .contentShape(Rectangle())
            }
            .disabled(theme.dots.count <= 1)
            Button {
                withAnimation(HarborDesign.Motion.quick) {
                    theme.addDot()
                    selectedID = theme.dots.last?.id
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                    .contentShape(Rectangle())
            }
            .disabled(theme.dots.count >= SpaceTheme.maxDots)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, HarborDesign.Spacing.xs)
    }

    private var dotGrid: some View {
        Canvas { context, size in
            let gap: CGFloat = 8
            var y = gap / 2
            while y < size.height {
                var x = gap / 2
                while x < size.width {
                    context.fill(Path(ellipseIn: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1)), with: .color(.primary.opacity(0.14)))
                    x += gap
                }
                y += gap
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Dragging

    /// A drag takes hold of the nearest dot and keeps it under the pointer. The model moves the
    /// rest with it, so the whole range of colors turns, or folds onto the middle.
    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if grab == nil {
                    guard let index = nearestDot(to: drag.startLocation) else { return }
                    let dot = theme.dots[index]
                    grab = (dot.id, CGSize(width: drag.startLocation.x - dot.x * canvasSize.width,
                                           height: drag.startLocation.y - dot.y * canvasSize.height))
                    selectedID = dot.id
                }
                guard let grab, let index = theme.dots.firstIndex(where: { $0.id == grab.id }) else { return }
                let x = (drag.location.x - grab.offset.width) / canvasSize.width
                let y = (drag.location.y - grab.offset.height) / canvasSize.height
                theme.drag(dotAt: index, toX: min(max(x, 0), 1), y: min(max(y, 0), 1))
            }
            .onEnded { _ in grab = nil }
    }

    private func nearestDot(to point: CGPoint) -> Int? {
        theme.dots.indices.min { lhs, rhs in
            distance(from: theme.dots[lhs], to: point) < distance(from: theme.dots[rhs], to: point)
        }
    }

    private func distance(from dot: SpaceTheme.Dot, to point: CGPoint) -> CGFloat {
        hypot(dot.x * canvasSize.width - point.x, dot.y * canvasSize.height - point.y)
    }

    // MARK: - Swatches

    private var swatchRow: some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            pageButton("chevron.left", step: -1)
            ForEach(Array(swatchPages[swatchPage].enumerated()), id: \.offset) { _, swatch in
                Button {
                    choose(swatch)
                } label: {
                    Circle()
                        .fill(Color(hex: swatch.hex))
                        .frame(width: swatchSize, height: swatchSize)
                        .overlay(Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            pageButton("chevron.right", step: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private func pageButton(_ symbol: String, step: Int) -> some View {
        let target = swatchPage + step
        return Button {
            withAnimation(HarborDesign.Motion.quick) { swatchPage = target }
        } label: {
            Image(systemName: symbol)
                .font(HarborDesign.Font.caption)
                .frame(width: HarborDesign.Spacing.lg, height: HarborDesign.Size.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(!swatchPages.indices.contains(target))
    }

    /// A swatch puts the chosen dot where its color sits on the map, and the others follow. The
    /// dot comes out exactly the color shown, a gray included: the rim of the map is the grays.
    private func choose(_ swatch: Swatch) {
        let index = selectedIndex
        guard theme.dots.indices.contains(index) else { return }
        let now = SpaceTheme.polar(x: theme.dots[index].x, y: theme.dots[index].y)
        let target: (x: Double, y: Double)
        switch swatch {
        case let .gray(level): target = SpaceTheme.position(forGray: level, near: now.angle)
        case let .wheel(angle, radius): target = SpaceTheme.unit(angle: angle, radius: radius)
        }
        withAnimation(HarborDesign.Motion.quick) {
            theme.drag(dotAt: index, toX: target.x, y: target.y)
        }
    }
}

// MARK: - Grain slider

/// A wavy track with a pill for a thumb: how much grain lies over the chrome.
private struct WavySlider: View {
    @Binding var value: Double

    private let height: CGFloat = 36
    private let thumbWidth: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let usable = proxy.size.width - thumbWidth
            ZStack(alignment: .leading) {
                Wave(amplitude: 3 + 7 * value)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(height: height)
                Capsule()
                    .fill(.white)
                    .frame(width: thumbWidth, height: height)
                    .offset(x: usable * value)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    value = min(max((drag.location.x - thumbWidth / 2) / max(usable, 1), 0), 1)
                })
        }
        .frame(height: height)
    }

    private struct Wave: Shape {
        var amplitude: Double

        var animatableData: Double {
            get { amplitude }
            set { amplitude = newValue }
        }

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let waves = 5.0
            for step in 0...Int(rect.width) {
                let x = Double(step)
                let y = rect.midY + amplitude * sin(x / rect.width * waves * 2 * .pi)
                step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
            }
            return path
        }
    }
}

// MARK: - Intensity dial

/// A knob ringed with dots, with no gap: turn it round and round to set how strongly the colors
/// show. It turns by how far the pointer travels round it, so a full turn is the whole range, and
/// turning past the end starts again from zero.
private struct IntensityDial: View {
    @Binding var value: Double

    private let diameter: CGFloat = 56
    private let ticks = 36
    /// Zero is at the top.
    private let start = -90.0
    @State private var lastAngle: Double?

    /// Where `fraction` of the way round the ring falls, from its center.
    private func point(at fraction: Double, radius: CGFloat) -> CGSize {
        let radians: Double = (start + 360 * fraction) * .pi / 180
        return CGSize(width: radius * CGFloat(cos(radians)), height: radius * CGFloat(sin(radians)))
    }

    var body: some View {
        ZStack {
            ForEach(0..<ticks, id: \.self) { index in
                let fraction = Double(index) / Double(ticks)
                Circle()
                    .fill(fraction < value || (index == 0 && value > 0) ? Color.primary : Color.primary.opacity(0.3))
                    .frame(width: 3, height: 3)
                    .offset(point(at: fraction, radius: diameter / 2 - 1.5))
            }
            Circle()
                .fill(Color.primary.opacity(0.12))
                .frame(width: diameter - 18, height: diameter - 18)
            Circle()
                .fill(Color.primary)
                .frame(width: 4, height: 4)
                .offset(point(at: value, radius: (diameter - 18) / 2 - 6))
        }
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                let dx = Double(drag.location.x - diameter / 2)
                let dy = Double(drag.location.y - diameter / 2)
                let angle: Double = atan2(dy, dx) * 180 / .pi
                defer { lastAngle = angle }
                guard let lastAngle else { return }
                // The step round the ring, taken the short way, so crossing the top is no jump.
                var step = angle - lastAngle
                if step > 180 { step -= 360 }
                if step < -180 { step += 360 }
                // Past the end it carries on from zero, and back past zero it carries on from the end.
                let next = value + step / 360
                value = next - next.rounded(.down)
            }
            .onEnded { _ in lastAngle = nil })
    }
}
