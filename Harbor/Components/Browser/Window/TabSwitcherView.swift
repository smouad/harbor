// Licensed under GPL-3.0. See LICENSE.
//
//  TabSwitcherView.swift
//  Harbor
//
//  The list Control-Tab shows: the window's tabs, most recently used first, with the one that
//  letting go of Control will open highlighted.
//

import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborUI
import HarborWeb

struct TabSwitcherView: View {
    let switcher: BrowserWindowState.TabSwitcher

    @Environment(TabsController.self) private var tabs

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: HarborDesign.Spacing.rowGap) {
                    ForEach(Array(switcher.items.enumerated()), id: \.element) { index, id in
                        if let item = tabs.item(id) {
                            row(item, selected: index == switcher.index)
                                .id(id)
                        }
                    }
                }
                .padding(HarborDesign.Spacing.sm)
            }
            .onChange(of: switcher.index) { _, index in
                guard switcher.items.indices.contains(index) else { return }
                proxy.scrollTo(switcher.items[index])
            }
        }
        .frame(width: 360)
        .frame(maxHeight: 420)
        .fixedSize(horizontal: false, vertical: true)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .allowsHitTesting(false)
    }

    private func row(_ item: Item, selected: Bool) -> some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            ItemFavicon(item: item, session: tabs.session(for: item.id))
                .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
            Text(tabs.title(for: item))
                .font(HarborDesign.Font.secondary)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, HarborDesign.Spacing.rowPadding)
        .frame(height: HarborDesign.Size.row)
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .harborRowSelection(selected, radius: HarborDesign.Radius.md)
    }
}
