// Licensed under GPL-3.0. See LICENSE.
//
//  AutofillDropdownView.swift
//  Harbor
//
//  The list that drops under a login field: each saved login with its password masked, and a
//  way into the full list. Drawn on Harbor's own card surface, laid over the page.
//

import SwiftUI
import HarborDesign
import HarborWeb

struct AutofillDropdownView: View {
    let logins: [SavedLogin]
    /// The row the arrow keys are on.
    let keyboardIndex: Int?
    let width: CGFloat
    /// The page's own host: a login saved for another host of the same site names that host.
    let pageHost: String
    let onPick: (SavedLogin) -> Void
    let onManage: () -> Void

    @State private var hoveredID: String?

    /// A row's height, fixed so the list can show a set number of them.
    private static let rowHeight: CGFloat = 46
    /// Rows in view before the list scrolls. A half row past it shows there is more.
    private static let visibleRows: CGFloat = 5

    private var listHeight: CGFloat {
        let count = CGFloat(logins.count)
        return (count > Self.visibleRows ? Self.visibleRows + 0.5 : count) * Self.rowHeight
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(Array(logins.enumerated()), id: \.element.id) { index, login in
                            row(login, highlighted: keyboardIndex == index || hoveredID == login.id)
                                .id(login.id)
                        }
                    }
                }
                .frame(height: listHeight)
                .onChange(of: keyboardIndex) { _, index in
                    guard let index, logins.indices.contains(index) else { return }
                    proxy.scrollTo(logins[index].id)
                }
            }
            Divider().padding(.horizontal, HarborDesign.Spacing.md)
            footer
        }
        .padding(.vertical, HarborDesign.Spacing.xs)
        .frame(width: width)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
    }

    private func row(_ login: SavedLogin, highlighted: Bool) -> some View {
        Button { onPick(login) } label: {
            HStack(spacing: HarborDesign.Spacing.md) {
                icon(for: login)
                    .frame(width: HarborDesign.Size.favicon, height: HarborDesign.Size.favicon)
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    HStack(spacing: HarborDesign.Spacing.md) {
                        Text(login.username)
                            .font(HarborDesign.Font.label)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if login.host.lowercased() != pageHost.lowercased() {
                            Text(login.host)
                                .font(HarborDesign.Font.secondary)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(String(repeating: "•", count: 14))
                        .font(HarborDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HarborDesign.Spacing.md)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HarborDesign.Radius.shape(HarborDesign.Radius.md)
                .fill(highlighted ? HarborDesign.Surface.fillPressed : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, HarborDesign.Spacing.xs)
        .onHover { inside in
            if inside { hoveredID = login.id } else if hoveredID == login.id { hoveredID = nil }
        }
    }

    @ViewBuilder
    private func icon(for login: SavedLogin) -> some View {
        if let image = FaviconCache.shared.swiftUIImage(for: login.host) {
            image.resizable().scaledToFit().clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
        } else {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        Button(action: onManage) {
            HStack(spacing: HarborDesign.Spacing.md) {
                Text("Manage Passwords…")
                    .font(HarborDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, HarborDesign.Spacing.lg)
            .padding(.vertical, HarborDesign.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
