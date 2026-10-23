// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarMenuTab.swift
//  Harbor
//
//  Created by Maciek Bagiński on 23/09/2025.
//

import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct SidebarMenuTab: View {
    var image: String
    var activeImage: String
    var title: String
    var isActive: Bool = true
    let action: () -> Void
    @State private var isHovering: Bool = false
    @State private var shouldWiggle: Bool = false

    private let height: CGFloat = 80

    var body: some View {
        Button {
            action()
            shouldWiggle.toggle()
        } label: {
            label
        }
        .buttonStyle(.plain)
        .onHoverTracking { state in
            isHovering = state
        }
    }

    private var label: some View {
        VStack(spacing: HarborDesign.Spacing.md) {
            Image(systemName: isActive ? activeImage : image)
                .font(HarborDesign.Font.titleLarge)
                .foregroundStyle(isActive ? .green : .primary)
                .symbolRenderingMode(.hierarchical)
                .symbolEffect(.wiggle, value: shouldWiggle)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .downUp.byLayer), options: .nonRepeating))

            Text(title)
                .font(HarborDesign.Font.secondary)
                .foregroundStyle(.primary)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        // The chosen tab takes the selected sidebar row's surface, so it takes no hover fill.
        .background(!isActive && isHovering ? HarborDesign.Surface.fill : .clear, in: HarborDesign.Radius.shape(HarborDesign.Radius.xl))
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.xl))
        .harborRowSelection(isActive, radius: HarborDesign.Radius.xl)
        .animation(HarborDesign.Motion.quick, value: isHovering)
        .animation(HarborDesign.Motion.standard, value: isActive)
    }
}
