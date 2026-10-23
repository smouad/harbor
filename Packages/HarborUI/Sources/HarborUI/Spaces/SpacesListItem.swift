// Licensed under GPL-3.0. See LICENSE.
//
//  SpacesListItem.swift
//  Harbor
//
//  Created by Maciek Bagiński on 04/08/2025.
//  Refactored by Aether on 15/11/2025.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb

struct SpacesListItem: View {
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState

    let space: SpaceRecord
    let isActive: Bool
    let isFaded: Bool
    let onHoverChange: ((Bool) -> Void)?

    @State private var isHovering: Bool = false
    @Environment(\.tabActions) private var actions

    private let dotSize: CGFloat = HarborDesign.Spacing.sm
    private let activeDotSize: CGFloat = HarborDesign.Spacing.md
    // A tight hit target so the 28pt default icon-button padding doesn't push the dots apart.
    private let buttonSize: CGFloat = HarborDesign.Spacing.xl

    init(
        space: SpaceRecord,
        isActive: Bool,
        isFaded: Bool,
        onHoverChange: ((Bool) -> Void)? = nil
    ) {
        self.space = space
        self.isActive = isActive
        self.isFaded = isFaded
        self.onHoverChange = onHoverChange
    }

    var body: some View {
        Button {
            Haptics.alignment()
            withAnimation(HarborDesign.Motion.standard) {
                tabs.setSpace(space.id, in: windowState)
            }
        } label: {
            spaceDot
        }
        .labelStyle(.iconOnly)
        .buttonStyle(HarborIconButtonStyle(size: buttonSize))
        .layoutPriority(isActive ? 1 : 0)
        .opacity(isFaded ? 0.3 : 1.0)
        .onHoverTracking { hovering in
            isHovering = hovering
            onHoverChange?(hovering)
        }
        .contextMenu {
            SpaceContextMenu(
                space: space,
                canDelete: tabs.switchableSpaces(for: windowState).count > 1,
                onOpenSettings: { actions?.openSpaceSettings() },
                onDeleteSpace: { tabs.deleteSpace(space.id) }
            )
            .environment(tabs)
            .environment(\.tabActions, actions)
        }
    }

    // MARK: - Dot

    @ViewBuilder
    private var spaceDot: some View {
        if space.isAgent {
            Image(systemName: "sparkles")
                .font(.system(size: HarborDesign.Size.spaceIcon, weight: .semibold))
                .foregroundStyle(HarborDesign.Surface.agentGradient)
        } else {
            plainDot
        }
    }

    private var plainDot: some View {
        Circle()
            .fill(isActive ? AnyShapeStyle(space.accentColor) : AnyShapeStyle(.tertiary))
            .frame(width: isActive ? activeDotSize : dotSize, height: isActive ? activeDotSize : dotSize)
            .animation(HarborDesign.Motion.standard, value: isActive)
    }
}
