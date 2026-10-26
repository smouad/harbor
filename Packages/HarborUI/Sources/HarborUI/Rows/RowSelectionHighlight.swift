// Licensed under GPL-3.0. See LICENSE.
//
//  RowSelectionHighlight.swift
//  HarborUI
//
//  The selected tab's highlight as one shape that glides from the old selection to the new one,
//  instead of each row fading its own in and out. A sidebar page puts a namespace in the
//  environment; the selected tab row, favorite tile or pinned row each draw the shape in their
//  background under the same id, and SwiftUI moves it between them, across the favorites grid and
//  the tab list alike. Without a namespace (a row shown elsewhere) the highlight is drawn in place.
//

import SwiftUI
import HarborDesign

private struct RowSelectionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

public extension EnvironmentValues {
    var rowSelectionNamespace: Namespace.ID? {
        get { self[RowSelectionNamespaceKey.self] }
        set { self[RowSelectionNamespaceKey.self] = newValue }
    }
}

/// The highlight is drawn the way the open-source browser Search (MIT, Office Commun,
/// github.com/driceroland/Search) draws its tab ground: in the row's background, as one clipped
/// shape that carries a shared `matchedGeometryEffect` id, with the landing animated on the
/// ground itself. The row's own dimming and its button label stay outside it, so a dimmed
/// (unloaded) row can never fade the highlight while it travels.
private struct RowSelectionHighlight: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat
    @Environment(\.rowSelectionNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.background {
            ground.animation(reduceMotion ? nil : HarborDesign.Motion.slide, value: isSelected)
        }
    }

    @ViewBuilder
    private var ground: some View {
        if isSelected {
            let shape = HarborDesign.Radius.shape(radius)
            let surface = ZStack {
                Rectangle().fill(HarborDesign.Surface.raised)
                Rectangle().strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth)
            }
            .clipShape(shape)
            if let namespace {
                surface.matchedGeometryEffect(id: "rowSelection", in: namespace)
            } else {
                surface.harborElevation(.raised)
            }
        }
    }
}

public extension View {
    /// The highlight behind a selected row or tile. Apply it to the row's outermost view, outside
    /// any dimming.
    func rowSelectionHighlight(_ isSelected: Bool, radius: CGFloat = HarborDesign.Radius.md) -> some View {
        modifier(RowSelectionHighlight(isSelected: isSelected, radius: radius))
    }
}
