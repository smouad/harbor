// Licensed under GPL-3.0. See LICENSE.
//
//  AgentStage.swift
//  Harbor
//
//  The AI Assistant's agent: Harbor looks for the Claude and Codex CLIs already on the Mac and
//  uses one of them, signed in as it is, with no API key. With both, the person picks; with one,
//  it is shown as the choice; with none, the step says where to get them and moves on.
//

import HarborDesign
import HarborSettings
import HarborUI
import SwiftUI

struct AgentStage: View {
    var accentHex: String
    /// The agents found on this Mac, nil while looking.
    var installed: [ACPClient.Preset]?
    @Binding var choice: AIProviderType?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        OnboardingStageLayout(title: title, message: message) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
                if let installed {
                    ForEach(installed, id: \.providerId) { preset in
                        agentRow(preset, selectable: installed.count > 1)
                    }
                } else {
                    HStack(spacing: HarborDesign.Spacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Claude and Codex…")
                            .font(HarborDesign.Font.body)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } preview: {
            OnboardingPreviewPanel(accentHex: accentHex) {
                AssistantPreview(agent: choice?.displayName, isDark: colorScheme == .dark)
            }
        }
    }

    private var title: String {
        switch installed?.count {
        case nil: return "Bring your AI agent"
        case 0: return "No AI agent found"
        case 1: return "\(installed?.first?.type.displayName ?? "Your agent") is ready"
        default: return "Which agent should Harbor use?"
        }
    }

    private var message: String {
        switch installed?.count {
        case nil, 1?:
            return "The AI Assistant (⇧⌘A) uses the agent already signed in on this Mac, with no API key. It can read pages and use the browser for you."
        case 0:
            return "Install Claude Code or Codex and sign in, and the AI Assistant (⇧⌘A) picks it up. You can also add an API provider in Settings › AI."
        default:
            return "Both Claude and Codex are on this Mac. Pick the one the AI Assistant (⇧⌘A) starts with; you can switch any time from its prompt box."
        }
    }

    private func agentRow(_ preset: ACPClient.Preset, selectable: Bool) -> some View {
        let selected = choice == preset.type
        return Button {
            choice = preset.type
        } label: {
            HStack(spacing: HarborDesign.Spacing.lg) {
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    Text(preset.type.displayName)
                        .font(HarborDesign.Font.body)
                        .foregroundStyle(.primary)
                    Text("Found `\(preset.cli)` on this Mac")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(HarborDesign.Font.title)
                    .foregroundStyle(selected ? Color(hex: accentHex) : Color.secondary)
            }
            .padding(HarborDesign.Spacing.lg)
            .background(HarborDesign.Radius.shape(HarborDesign.Radius.lg).fill(HarborDesign.Surface.fill))
            .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The AI Assistant's panel in miniature, with the chosen agent in its prompt box.
private struct AssistantPreview: View {
    var agent: String?
    var isDark: Bool

    private var ink: Color { isDark ? .white : .black }

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            Text("Ask Harbor")
                .font(HarborDesign.Font.label)
                .foregroundStyle(ink.opacity(0.8))
            HStack {
                Spacer()
                Text("Summarize this page")
                    .font(HarborDesign.Font.caption)
                    .padding(HarborDesign.Spacing.sm)
                    .background(HarborDesign.Radius.shape(HarborDesign.Radius.md).fill(ink.opacity(0.1)))
            }
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.sm) {
                ForEach([200, 230, 150], id: \.self) { width in
                    Capsule().fill(ink.opacity(0.12)).frame(width: CGFloat(width), height: 6)
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(agent.map { "\($0) · its default" } ?? "Choose an agent")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(ink.opacity(0.6))
                Spacer()
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(ink.opacity(0.3))
            }
            .padding(HarborDesign.Spacing.md)
            .background(HarborDesign.Radius.shape(HarborDesign.Radius.lg).fill(ink.opacity(0.06)))
        }
        .padding(HarborDesign.Spacing.xl)
        .frame(width: 300, height: 300, alignment: .topLeading)
        .background(HarborDesign.Radius.shape(HarborDesign.Radius.md).fill(isDark ? Color(white: 0.17) : .white))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .animation(HarborDesign.Motion.standard, value: agent)
        .accessibilityHidden(true)
    }
}
