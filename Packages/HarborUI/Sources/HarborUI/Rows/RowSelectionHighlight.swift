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

private struct SelectionShape: View {
    let radius: CGFloat

    var body: some View {
        let shape = HarborDesign.Radius.shape(radius)
        shape
            .fill(HarborDesign.Surface.raised)
            .overlay(shape.strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth))
            .harborElevation(.raised)
    }
}

private struct RowSelectionHighlight: ViewModifier {
    let isSelected: Bool
    let radius: CGFloat
    @Environment(\.rowSelectionNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.background {
                if isSelected {
                    SelectionShape(radius: radius)
                        .matchedGeometryEffect(id: "rowSelection", in: namespace)
                }
            }
        } else {
            content
                .harborRowSelection(isSelected, radius: radius)
                .harborElevation(isSelected ? .raised : .flat)
        }
    }
}

public extension View {
    /// The highlight behind a selected row or tile.
    func rowSelectionHighlight(_ isSelected: Bool, radius: CGFloat = HarborDesign.Radius.md) -> some View {
        modifier(RowSelectionHighlight(isSelected: isSelected, radius: radius))
    }
}
