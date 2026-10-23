// Licensed under GPL-3.0. See LICENSE.
//
//  OnboardingWindowPreview.swift
//  Harbor
//
//  A small drawing of a Harbor window for the steps that change how one looks: the space color
//  tints the sidebar, and the address sits over the page or at the top of the sidebar. Drawn in
//  shapes rather than screenshots, so it follows each choice as it is made.
//

import HarborDesign
import SwiftUI

struct OnboardingWindowPreview: View {
    var accentHex: String
    var addressOnTop: Bool
    var isDark: Bool = false
    var width: CGFloat = 360

    /// Every measurement below is in points of a 360pt-wide drawing, scaled by `unit`.
    private var unit: CGFloat { width / 360 }
    private let height: CGFloat = 228
    private let inset: CGFloat = 8
    private let sidebarWidth: CGFloat = 96
    private let bandHeight: CGFloat = 22

    private var ink: Color { isDark ? .white : .black }
    private var base: Color { isDark ? Color(white: 0.11) : Color(white: 0.96) }
    private var pageFill: Color { isDark ? Color(white: 0.17) : .white }
    private var controlFill: Color { isDark ? Color.white.opacity(0.1) : Color.white.opacity(0.6) }

    var body: some View {
        let accent = Color(hex: accentHex)
        let shape = HarborDesign.Radius.shape(10 * unit)

        ZStack(alignment: .topLeading) {
            LinearGradient(
                colors: [accent.mix(with: base, by: isDark ? 0.35 : 0.45), accent.mix(with: base, by: isDark ? 0.7 : 0.8)],
                startPoint: .top, endPoint: .bottom)
            HarborGrain()

            trafficLights
                .offset(x: 12 * unit, y: 9 * unit)
            sidebar
                .offset(x: inset * unit, y: (addressOnTop ? 28 : 26) * unit)
            if addressOnTop {
                topBar
                    .offset(x: (inset * 2 + sidebarWidth) * unit, y: 4 * unit)
            }
            page
                .offset(x: (inset * 2 + sidebarWidth) * unit, y: (addressOnTop ? inset + bandHeight : inset) * unit)
        }
        .frame(width: width, height: height * unit, alignment: .topLeading)
        .clipShape(shape)
        .overlay(shape.strokeBorder(ink.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 24 * unit, y: 12 * unit)
        .animation(HarborDesign.Motion.standard, value: accentHex)
        .animation(HarborDesign.Motion.standard, value: addressOnTop)
        .animation(HarborDesign.Motion.standard, value: isDark)
        .accessibilityHidden(true)
    }

    private var trafficLights: some View {
        HStack(spacing: 4 * unit) {
            ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) { hex in
                Circle().fill(Color(hex: hex)).frame(width: 7 * unit, height: 7 * unit)
            }
        }
    }

    private var sidebar: some View {
        let tile = (sidebarWidth - 2 * 6) / 3
        return VStack(alignment: .leading, spacing: 6 * unit) {
            if !addressOnTop {
                HarborDesign.Radius.shape(4 * unit)
                    .fill(controlFill)
                    .frame(width: sidebarWidth * unit, height: 14 * unit)
                    .overlay(alignment: .leading) { line(width: 46).padding(.leading, 6 * unit) }
            }
            VStack(spacing: 6 * unit) {
                ForEach(0..<2, id: \.self) { _ in
                    HStack(spacing: 6 * unit) {
                        ForEach(0..<3, id: \.self) { _ in
                            HarborDesign.Radius.shape(4 * unit)
                                .fill(controlFill)
                                .frame(width: tile * unit, height: 20 * unit)
                        }
                    }
                }
            }
            .padding(.bottom, 2 * unit)
            ForEach(Array([58, 70, 44, 62, 50].enumerated()), id: \.offset) { index, length in
                HStack(spacing: 5 * unit) {
                    Circle().fill(ink.opacity(0.22)).frame(width: 6 * unit, height: 6 * unit)
                    line(width: CGFloat(length))
                }
                .padding(.horizontal, 5 * unit)
                .frame(width: sidebarWidth * unit, height: 13 * unit, alignment: .leading)
                .background(
                    HarborDesign.Radius.shape(3 * unit).fill(index == 0 ? pageFill : .clear)
                )
            }
        }
    }

    private var topBar: some View {
        let pageWidth = 360 - inset * 3 - sidebarWidth
        return HStack(spacing: 5 * unit) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(ink.opacity(0.14)).frame(width: 7 * unit, height: 7 * unit)
            }
            Spacer(minLength: 0)
        }
        .overlay {
            Capsule()
                .fill(ink.opacity(0.07))
                .frame(width: 110 * unit, height: 12 * unit)
                .overlay { line(width: 54) }
        }
        .frame(width: pageWidth * unit, height: bandHeight * unit)
    }

    private var page: some View {
        let pageWidth = 360 - inset * 3 - sidebarWidth
        let pageHeight = height - inset * 2 - (addressOnTop ? bandHeight : 0)
        return VStack(alignment: .leading, spacing: 7 * unit) {
            HarborDesign.Radius.shape(2 * unit).fill(ink.opacity(0.2))
                .frame(width: 92 * unit, height: 9 * unit)
                .padding(.bottom, 4 * unit)
            ForEach(Array([196, 180, 204, 150, 188, 120].enumerated()), id: \.offset) { _, length in
                line(width: CGFloat(length))
            }
        }
        .padding(16 * unit)
        .frame(width: pageWidth * unit, height: pageHeight * unit, alignment: .topLeading)
        .background(HarborDesign.Radius.shape(6 * unit).fill(pageFill))
        .shadow(color: .black.opacity(0.1), radius: 2 * unit, y: 1 * unit)
    }

    private func line(width length: CGFloat) -> some View {
        Capsule().fill(ink.opacity(0.12)).frame(width: length * unit, height: 4 * unit)
    }
}
