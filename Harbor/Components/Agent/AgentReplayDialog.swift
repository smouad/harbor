// Licensed under GPL-3.0. See LICENSE.
//
//  AgentReplayDialog.swift
//  Harbor
//
//  A task's run, step by step: what the agent did, whether it worked, and what the page looked
//  like after each step that changed it. Read from AgentReplay, so it fills in as the task runs.
//

import AppKit
import SwiftUI
import HarborDesign
import HarborUI

struct AgentReplayDialog: DialogPresentable {
    let task: AgentTask
    let onClose: () -> Void

    func dialogHeader() -> DialogHeader {
        DialogHeader(icon: "clock.arrow.circlepath", title: "Replay", subtitle: task.title)
    }

    @ViewBuilder
    func dialogContent() -> some View {
        AgentReplayContent(task: task)
    }

    func dialogFooter() -> DialogFooter {
        DialogFooter(rightButtons: [
            DialogButton(text: "Show in Finder", variant: .secondary) {
                NSWorkspace.shared.activateFileViewerSelecting([AgentReplay.directory(for: task.id)])
            },
            DialogButton(text: "Close", variant: .primary, action: onClose)
        ])
    }
}

private struct AgentReplayContent: View {
    let task: AgentTask
    @State private var selected: Int?

    private var steps: [AgentReplay.Step] { AgentHub.shared.replay.steps(for: task) }

    var body: some View {
        if steps.isEmpty {
            Text("No steps yet.")
                .font(HarborDesign.Font.bodyRegular)
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .top, spacing: HarborDesign.Spacing.lg) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                        ForEach(steps) { step in
                            row(step)
                        }
                    }
                }
                .frame(width: Self.listWidth, height: Self.height)
                frame
                    .frame(maxWidth: .infinity, maxHeight: Self.height)
            }
            .onAppear { selected = steps.last(where: { $0.frame != nil })?.id ?? steps.last?.id }
        }
    }

    private func row(_ step: AgentReplay.Step) -> some View {
        HStack(alignment: .top, spacing: HarborDesign.Spacing.md) {
            Image(systemName: step.ok ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(step.ok ? Color.secondary : HarborDesign.Surface.danger)
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text("\(step.id). \(step.tool)")
                    .font(HarborDesign.Font.body)
                Text(step.detail.isEmpty ? step.summary : step.detail)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(HarborDesign.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .harborRowSelection(selected == step.id)
        .contentShape(Rectangle())
        .onTapGesture { selected = step.id }
    }

    @ViewBuilder
    private var frame: some View {
        // The picture of the selected step, or of the last step before it that has one.
        let shown = steps.last { $0.id <= (selected ?? 0) && $0.frame != nil }
        if let url = shown?.frame, let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        } else {
            Text("No picture for this step.")
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private static let listWidth: CGFloat = 260
    private static let height: CGFloat = 360
}
