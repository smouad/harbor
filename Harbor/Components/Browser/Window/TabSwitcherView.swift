// Licensed under GPL-3.0. See LICENSE.
//
//  TabSwitcherView.swift
//  Harbor
//
//  What Control-Tab shows: a row of cards, one per tab and most recently used first, each with a
//  picture of the page and its title. The card letting go of Control will open is highlighted.
//

import AppKit
import ImageIO
import SwiftUI
import HarborDesign
import HarborTabsCore
import HarborUI
import HarborWeb

struct TabSwitcherView: View {
    let switcher: BrowserWindowState.TabSwitcher

    @Environment(TabsController.self) private var tabs

    private let cardWidth: CGFloat = 176
    private let pictureHeight: CGFloat = 112

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HarborDesign.Spacing.sm) {
                    ForEach(Array(switcher.items.enumerated()), id: \.element) { index, id in
                        if let item = tabs.item(id) {
                            card(item, selected: index == switcher.index)
                                .id(id)
                        }
                    }
                }
                .padding(HarborDesign.Spacing.md)
            }
            .onChange(of: switcher.index) { _, index in
                guard switcher.items.indices.contains(index) else { return }
                withAnimation(HarborDesign.Motion.quick) { proxy.scrollTo(switcher.items[index], anchor: .center) }
            }
        }
        // Five cards at most (`TabsController.switcherLimit`), so it never needs to scroll.
        .fixedSize(horizontal: true, vertical: true)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .allowsHitTesting(false)
    }

    private func card(_ item: Item, selected: Bool) -> some View {
        let session = tabs.session(for: item.id)
        return VStack(spacing: HarborDesign.Spacing.sm) {
            picture(item, session: session)
                .frame(width: cardWidth - HarborDesign.Spacing.sm * 2, height: pictureHeight)
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
            HStack(spacing: HarborDesign.Spacing.sm) {
                ItemFavicon(item: item, session: session)
                    .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
                Text(tabs.title(for: item))
                    .font(HarborDesign.Font.secondary)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HarborDesign.Spacing.xs)
        }
        .padding(HarborDesign.Spacing.sm)
        .frame(width: cardWidth)
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .harborRowSelection(selected, radius: HarborDesign.Radius.lg)
    }

    /// The tab's last picture, else the one kept when it was unloaded, else its icon on a plain card.
    @ViewBuilder
    private func picture(_ item: Item, session: PageSession?) -> some View {
        if let image = Self.image(from: session?.thumbnail ?? session?.unloadSnapshot) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ZStack {
                HarborDesign.Surface.fill
                ItemFavicon(item: item, session: session)
                    .frame(width: HarborDesign.Size.essentialsTile / 2, height: HarborDesign.Size.essentialsTile / 2)
                    .opacity(0.8)
            }
        }
    }

    private static func image(from jpeg: Data?) -> NSImage? {
        guard let jpeg, let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
    }
}
