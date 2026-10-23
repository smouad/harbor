// Licensed under GPL-3.0. See LICENSE.
//
//  DevConsoleView.swift
//  Harbor
//
//  Console tab: the page's console, errors and failed loads, plus an evaluate field.
//

import AppKit
import SwiftUI
import HarborDesign
import HarborWeb
import HarborUI

struct DevConsoleView: View {
    let capture: DevCapture?
    let session: PageSession?

    enum Filter: String, CaseIterable { case all = "All", errors = "Errors", warnings = "Warnings", logs = "Logs" }

    @EnvironmentObject var browserManager: BrowserManager
    @State private var filter: Filter = .all
    @State private var search = ""
    @State private var input = ""

    var body: some View {
        if let capture {
            VStack(spacing: 0) {
                toolbar(capture)
                list(capture)
                inputField
            }
        } else {
            DevPanelEmpty()
        }
    }

    private func toolbar(_ capture: DevCapture) -> some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            Picker("", selection: $filter) {
                ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            TextField("Filter", text: $search)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.secondary)
                .padding(.horizontal, HarborDesign.Spacing.sm)
                .frame(height: HarborDesign.Size.iconButton)
                .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
            Button("Clear", systemImage: "trash") { capture.clearConsole() }
                .harborIconButtons()
        }
        .padding(HarborDesign.Spacing.md)
    }

    private func visible(_ capture: DevCapture) -> [DevConsoleEntry] {
        let term = search.lowercased()
        return capture.console.items.filter { e in
            switch filter {
            case .all: break
            case .errors: guard e.isError else { return false }
            case .warnings: guard e.isWarning else { return false }
            case .logs: guard !e.isError && !e.isWarning else { return false }
            }
            return term.isEmpty || e.message.lowercased().contains(term)
        }
    }

    private func list(_ capture: DevCapture) -> some View {
        ScrollViewReader { proxy in
            List {
                let dropped = capture.droppedMessages + capture.console.dropped
                if dropped > 0 {
                    Text("\(dropped) messages dropped")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
                ForEach(visible(capture)) { entry in
                    DevConsoleRow(entry: entry) {
                        browserManager.handOff(DevPick(markdown: DevHandoff.markdown(console: entry, pageURL: session?.url.absoluteString)), from: session)
                    }
                    .id(entry.id)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: capture.console.lastSeq) {
                if let last = capture.console.items.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var inputField: some View {
        HStack(spacing: HarborDesign.Spacing.sm) {
            Image(systemName: "chevron.right")
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.tertiary)
            TextField("", text: $input)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.secondary.monospaced())
                .onSubmit {
                    let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !code.isEmpty, let session else { return }
                    input = ""
                    Task { await session.devEvaluate(code) }
                }
        }
        .padding(.horizontal, HarborDesign.Spacing.md)
        .frame(height: HarborDesign.Size.chromeControl)
        .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .padding(HarborDesign.Spacing.md)
    }
}

private struct DevConsoleRow: View {
    let entry: DevConsoleEntry
    let sendToAgent: () -> Void

    private var tint: Color {
        if entry.isError { return .red }
        if entry.isWarning { return .orange }
        return .primary
    }

    private var glyph: String? {
        switch entry.level {
        case "input": return "chevron.right"
        case "result": return "arrow.left"
        default: return entry.isError ? "xmark.octagon.fill" : entry.isWarning ? "exclamationmark.triangle.fill" : nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HarborDesign.Spacing.sm) {
            if let glyph {
                Image(systemName: glyph)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(entry.isError || entry.isWarning ? tint : .secondary)
            }
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(entry.message)
                    .font(HarborDesign.Font.secondary.monospaced())
                    .foregroundStyle(entry.isError || entry.isWarning ? tint : .primary)
                    .lineLimit(12)
                    .textSelection(.enabled)
                if let location = entry.location ?? entry.frameURL {
                    Text(location)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if entry.repeatCount > 1 {
                Text("\(entry.repeatCount)")
                    .font(HarborDesign.Font.micro)
                    .padding(.horizontal, HarborDesign.Spacing.xs)
                    .background(Capsule().fill(HarborDesign.Surface.fill))
            }
        }
        .contextMenu {
            Button("Send to Agent", action: sendToAgent)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.message, forType: .string)
            }
        }
    }
}
