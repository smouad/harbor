// Licensed under GPL-3.0. See LICENSE.
//
//  DevNetworkView.swift
//  Harbor
//
//  Network tab: fetch and XHR with headers and bodies, everything else from Resource Timing.
//

import AppKit
import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct DevNetworkView: View {
    let capture: DevCapture?
    let session: PageSession?
    @EnvironmentObject var browserManager: BrowserManager

    @State private var search = ""
    @State private var selectedID: Int?

    var body: some View {
        if let capture {
            VStack(spacing: 0) {
                HStack(spacing: HarborDesign.Spacing.sm) {
                    TextField("Filter", text: $search)
                        .textFieldStyle(.plain)
                        .font(HarborDesign.Font.secondary)
                        .padding(.horizontal, HarborDesign.Spacing.sm)
                        .frame(height: HarborDesign.Size.iconButton)
                        .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
                }
                .padding(HarborDesign.Spacing.md)

                List(visible(capture), selection: $selectedID) { entry in
                    DevNetworkRow(entry: entry).tag(entry.id)
                        .contextMenu {
                            Button("Send to Agent") {
                                browserManager.handOff(DevPick(markdown: DevHandoff.markdown(network: entry, pageURL: session?.url.absoluteString)), from: session)
                            }
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)

                if let id = selectedID, let entry = capture.network.items.first(where: { $0.id == id }) {
                    Divider()
                    DevNetworkDetail(entry: entry)
                        .frame(maxHeight: HarborDesign.Size.sheetSmallHeight)
                }
            }
        } else {
            DevPanelEmpty()
        }
    }

    private func visible(_ capture: DevCapture) -> [DevNetworkEntry] {
        let term = search.lowercased()
        guard !term.isEmpty else { return capture.network.items }
        return capture.network.items.filter { $0.url.lowercased().contains(term) || $0.kind.contains(term) }
    }
}

private struct DevNetworkRow: View {
    let entry: DevNetworkEntry

    private var statusText: String {
        switch entry.state {
        case .pending: return "…"
        case .failed: return "✕"
        case .done: return entry.status.map(String.init) ?? "–"
        }
    }

    private var failed: Bool { entry.state == .failed || (entry.status ?? 0) >= 400 }

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            Text(statusText)
                .font(HarborDesign.Font.caption.monospacedDigit())
                .foregroundStyle(failed ? .red : .secondary)
                .frame(width: HarborDesign.Size.iconButton, alignment: .leading)
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.name)
                    .font(HarborDesign.Font.secondary)
                    .foregroundStyle(failed ? .red : .primary)
                    .lineLimit(1)
                Text("\(entry.method) · \(entry.kind)")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if let ms = entry.duration {
                Text("\(Int(ms.rounded())) ms")
                    .font(HarborDesign.Font.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct DevNetworkDetail: View {
    let entry: DevNetworkEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
                Text(entry.url)
                    .font(HarborDesign.Font.secondary.monospaced())
                    .textSelection(.enabled)
                if let error = entry.error {
                    Text(error).font(HarborDesign.Font.secondary).foregroundStyle(.red)
                }
                if entry.hasDetail {
                    Button("Copy as cURL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.curl, forType: .string)
                    }
                    .buttonStyle(RectNavButtonStyle())
                    headers("Request Headers", entry.requestHeaders)
                    body("Request Body", entry.requestBody)
                    headers("Response Headers", entry.responseHeaders)
                    body("Response Body", entry.responseBody)
                } else {
                    Text("Loads started by the page's HTML carry no headers here. Use Web Inspector.")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HarborDesign.Spacing.md)
        }
    }

    @ViewBuilder
    private func headers(_ title: String, _ values: [String: String]) -> some View {
        if !values.isEmpty {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(title).font(HarborDesign.Font.captionStrong).foregroundStyle(.secondary)
                ForEach(values.sorted(by: { $0.key < $1.key }), id: \.key) { name, value in
                    Text("\(name): \(value)")
                        .font(HarborDesign.Font.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func body(_ title: String, _ text: String?) -> some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(title).font(HarborDesign.Font.captionStrong).foregroundStyle(.secondary)
                Text(text)
                    .font(HarborDesign.Font.caption.monospaced())
                    .lineLimit(40)
                    .textSelection(.enabled)
            }
        }
    }
}
