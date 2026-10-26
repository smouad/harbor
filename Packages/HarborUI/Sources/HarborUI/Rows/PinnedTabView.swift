// Licensed under GPL-3.0. See LICENSE.
//
//  PinnedButtonView.swift
//  Harbor
//
//  Created by Maciek Bagiński on 30/07/2025.
//

import SwiftUI
import HarborDesign

public struct PinnedTabView<Icon: View>: View {
    var tabName: String
    var tabURL: String
    var tabIcon: Icon
    var isActive: Bool
    var isUnloaded: Bool = false
    /// The favorite's open page has left its pinned URL; hovering shows a reset button.
    var hasLeftPinnedURL: Bool = false
    var onResetToPinnedURL: () -> Void = {}
    var action: () -> Void

    @State private var isHovered: Bool = false

    public init(
        tabName: String,
        tabURL: String,
        tabIcon: Icon,
        isActive: Bool,
        isUnloaded: Bool = false,
        hasLeftPinnedURL: Bool = false,
        onResetToPinnedURL: @escaping () -> Void = {},
        action: @escaping () -> Void
    ) {
        self.tabName = tabName
        self.tabURL = tabURL
        self.tabIcon = tabIcon
        self.isActive = isActive
        self.isUnloaded = isUnloaded
        self.hasLeftPinnedURL = hasLeftPinnedURL
        self.onResetToPinnedURL = onResetToPinnedURL
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                HarborDesign.Radius.shape(HarborDesign.Radius.tile)
                    .fill(backgroundColor)
                    .animation(HarborDesign.Motion.quick, value: isHovered)

                tabIcon
                    .frame(height: HarborDesign.Size.essentialsFavicon)
                    .opacity(isUnloaded ? HarborDesign.Surface.unloadedOpacity : 1)
            }
            .overlay(alignment: .topTrailing) {
                if hasLeftPinnedURL && isHovered {
                    Button(action: onResetToPinnedURL) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.primary)
                            .frame(width: HarborDesign.Size.cornerButton, height: HarborDesign.Size.cornerButton)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Reset to Pinned URL")
                    .padding(HarborDesign.Spacing.xxs)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: HarborDesign.Size.essentialsTile)
            .frame(minWidth: HarborDesign.Size.essentialsTile)
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.tile))
            .rowSelectionHighlight(isActive, radius: HarborDesign.Radius.tile)
        }
        .buttonStyle(.plain)
        .onHoverTracking { hovering in
            self.isHovered = hovering
        }
    }

    //MARK: - Colors
    /// Clear when selected: `harborRowSelection` draws the raised surface.
    private var backgroundColor: Color {
        isActive ? .clear : (isHovered ? HarborDesign.Surface.fillPressed : HarborDesign.Surface.fill)
    }
}
