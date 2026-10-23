// Licensed under GPL-3.0. See LICENSE.
//
//  SplitHalfLabel.swift
//  HarborUI
//
//  One half of the sidebar's split row: everything but the drag source, which is an
//  AppKit view the app wraps around this.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborWeb

public struct SplitHalfLabel: View {
    let item: Item

    @State private var isHovering: Bool = false
    @State private var isCloseHovering: Bool = false
    @Environment(TabsController.self) private var tabs
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.tabActions) private var actions

    public init(item: Item) {
        self.item = item
    }

    public var body: some View {
        let title = tabs.title(for: item)
        let session = tabs.session(for: item.id)
        Button(action: { tabs.select(item.id, in: windowState) }) {
            HStack(spacing: HarborDesign.Spacing.md) {
                ItemFavicon(item: item, session: session)
                    .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
                Text(title)
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: HarborDesign.Spacing.xs)
                if isHovering {
                    Button(action: { tabs.close(item.id) }) {
                        Image(systemName: "xmark")
                            .font(HarborDesign.Font.secondary)
                            .foregroundColor(.primary)
                            .frame(width: HarborDesign.Size.rowButton, height: HarborDesign.Size.rowButton)
                            .background(isCloseHovering ? HarborDesign.Surface.fillPressed : Color.clear)
                            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onHoverTracking { state in
                        isCloseHovering = state
                    }
                }
            }
            .padding(.horizontal, HarborDesign.Spacing.rowPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovering = hovering
            }
        }
        .contextMenu {
            TabContextMenu(itemID: item.id, context: .split)
                .environment(windowState)
                .environment(tabs)
                .environment(\.tabActions, actions)
        }
        .background(isHovering ? HarborDesign.Surface.fill : Color.clear)
    }
}
