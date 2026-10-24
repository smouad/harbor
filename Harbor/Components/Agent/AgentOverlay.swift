// Licensed under GPL-3.0. See LICENSE.
//
//  AgentOverlay.swift
//  Harbor
//
//  The agent's cards over the page. In every window: actions waiting for the person's approval,
//  tasks that handed the person a step, and a recording in progress. In the Agent space, also the
//  task list: each task's status and note, with watch, take over or hand back, replay and stop;
//  and the saved recipes, each with Run (or Stop) and how its last run went.
//

import SwiftUI
import HarborDesign
import HarborUI
import HarborWeb

struct AgentOverlay: View {
    @EnvironmentObject private var browserManager: BrowserManager
    @Environment(BrowserWindowState.self) private var windowState
    private let hub = AgentHub.shared

    private var showsAgentSpace: Bool {
        windowState.spaceID != nil && windowState.spaceID == browserManager.tabs.agentSpaceID
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: HarborDesign.Spacing.md) {
            ForEach(hub.approvals.pending) { request in
                AgentApprovalCard(request: request)
            }
            ForEach(hub.tasks.needingPerson) { task in
                AgentHandoffCard(task: task, window: windowState)
            }
            if hub.recorder.isRecording {
                AgentRecordingCard()
            }
            if showsAgentSpace, !hub.tasks.all.isEmpty {
                AgentTasksCard(window: windowState)
            }
            if showsAgentSpace, !hub.recipes.all.isEmpty, !hub.recorder.isRecording {
                AgentRecipesCard()
            }
        }
        .frame(maxWidth: Self.cardWidth, alignment: .trailing)
        .padding(HarborDesign.Spacing.xl)
        .animation(HarborDesign.Motion.spring, value: hub.approvals.pending.map(\.id))
        .animation(HarborDesign.Motion.spring, value: hub.tasks.needingPerson.map(\.id))
    }

    static let cardWidth: CGFloat = 340
}

// MARK: - Approval

private struct AgentApprovalCard: View {
    let request: AgentApprovals.Request

    var body: some View {
        AgentCard(symbol: "hand.raised", title: "Approve agent action?", detail: request.taskTitle) {
            Text(request.action)
                .font(HarborDesign.Font.body)
                .fixedSize(horizontal: false, vertical: true)
            Text(request.reason)
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.secondary)
        } actions: {
            Button("Deny") { AgentHub.shared.approvals.decide(request.id, allow: false) }
            // No default action: a Return meant for the page must never approve a purchase.
            Button("Allow") { AgentHub.shared.approvals.decide(request.id, allow: true) }
        }
    }
}

// MARK: - Handoff

private struct AgentHandoffCard: View {
    let task: AgentTask
    let window: BrowserWindowState

    private var reason: String {
        if case .needsYou(let reason) = task.status { return reason }
        return ""
    }

    var body: some View {
        AgentCard(symbol: "person.crop.circle.badge.exclamationmark", title: "Agent needs you", detail: task.title) {
            Text(reason)
                .font(HarborDesign.Font.body)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Show") { AgentHub.shared.tasks.watch(task, in: window) }
            Button("Done, continue") { AgentHub.shared.tasks.handBack(task) }
        }
    }
}

// MARK: - Recording

private struct AgentRecordingCard: View {
    @State private var name = ""
    @State private var error: String?
    private let recorder = AgentHub.shared.recorder

    var body: some View {
        AgentCard(symbol: "record.circle", title: "Recording a recipe", detail: recorder.subject) {
            Text("\(recorder.steps.count) \(recorder.steps.count == 1 ? "step" : "steps")")
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.secondary)
            TextField("Recipe name", text: $name)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.body)
                .padding(.horizontal, HarborDesign.Spacing.md)
                .frame(height: HarborDesign.Size.navRow)
                .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
                .onSubmit(save)
            if let error {
                Text(error)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(HarborDesign.Surface.danger)
            }
        } actions: {
            Button("Discard") { recorder.stop() }
            Button("Save", action: save)
                .disabled(name.isEmpty)
        }
    }

    private func save() {
        do {
            let recipe = try recorder.recipe(name: name, description: "", expose: false)
            try AgentHub.shared.recipes.save(recipe)
            recorder.stop()
        } catch {
            self.error = error.agentMessage
        }
    }
}

// MARK: - Tasks

private struct AgentTasksCard: View {
    let window: BrowserWindowState
    @EnvironmentObject private var browserManager: BrowserManager
    private let hub = AgentHub.shared

    /// Running tasks first, then the latest finished ones.
    private var shown: [AgentTask] {
        let active = hub.tasks.active
        let finished = hub.tasks.all.filter(\.isFinished).suffix(max(0, Self.maxRows - active.count)).reversed()
        return Array((active + finished).prefix(Self.maxRows))
    }

    static let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
            HStack {
                Text("Agent tasks")
                    .font(HarborDesign.Font.captionStrong)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if hub.tasks.all.contains(where: \.isFinished) {
                    Button("Clear") { hub.tasks.clearFinished() }
                        .buttonStyle(RectNavButtonStyle())
                        .controlSize(.small)
                        .help("Remove finished tasks and close their tabs")
                }
            }
            .padding(.leading, HarborDesign.Spacing.md)
            .padding(.top, HarborDesign.Spacing.xs)
            ForEach(shown) { task in
                AgentTaskRow(task: task, window: window)
            }
        }
        .padding(HarborDesign.Spacing.xs)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
    }
}

private struct AgentTaskRow: View {
    let task: AgentTask
    let window: BrowserWindowState
    @EnvironmentObject private var browserManager: BrowserManager

    private var isSelected: Bool { window.selectedItemID == task.itemID }

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            AgentStatusDot(status: task.status)
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(task.title)
                    .font(HarborDesign.Font.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: HarborDesign.Spacing.xxs) {
                if !task.isFinished {
                    if task.isPausedForPerson {
                        Button { AgentHub.shared.tasks.handBack(task) } label: { Image(systemName: "play.fill") }
                            .help("Hand back to the agent")
                            .accessibilityLabel("Hand back to the agent")
                    } else {
                        Button { AgentHub.shared.tasks.takeOver(task, in: window) } label: { Image(systemName: "hand.raised") }
                            .help("Take over")
                            .accessibilityLabel("Take over")
                    }
                }
                Button { browserManager.showDialog(AgentReplayDialog(task: task) { browserManager.dialogManager.closeDialog() }) } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .help("Replay")
                .accessibilityLabel("Replay")
                if !task.isFinished {
                    Button { AgentHub.shared.tasks.stop(task) } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                        .accessibilityLabel("Stop")
                }
            }
            .harborIconButtons()
        }
        .padding(.horizontal, HarborDesign.Spacing.md)
        .padding(.vertical, HarborDesign.Spacing.sm)
        .harborRowSelection(isSelected)
        .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .onTapGesture { AgentHub.shared.tasks.watch(task, in: window) }
    }

    private var subtitle: String {
        switch task.status {
        case .needsYou(let reason): return reason
        case .personControl: return "You have control"
        case .done(let summary): return summary ?? "Done"
        case .failed(let summary): return summary ?? "Failed"
        case .stopped: return "Stopped"
        case .running: return task.note ?? "\(task.steps) \(task.steps == 1 ? "step" : "steps")"
        }
    }
}

// MARK: - Recipes

private struct AgentRecipesCard: View {
    private let hub = AgentHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
            Text("Recipes")
                .font(HarborDesign.Font.captionStrong)
                .foregroundStyle(.secondary)
                .padding(.leading, HarborDesign.Spacing.md)
                .padding(.top, HarborDesign.Spacing.xs)
            ForEach(hub.recipes.all.prefix(Self.maxRows), id: \.name) { recipe in
                AgentRecipeRow(recipe: recipe)
            }
        }
        .padding(HarborDesign.Spacing.xs)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
    }

    static let maxRows = 6
}

private struct AgentRecipeRow: View {
    let recipe: AgentRecipe
    @State private var error: String?
    private let hub = AgentHub.shared

    /// This recipe's latest run.
    private var job: AgentJob? {
        hub.jobs.all.last { $0.kind == "recipe" && $0.title == recipe.name }
    }

    var body: some View {
        HStack(spacing: HarborDesign.Spacing.md) {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(recipe.name)
                    .font(HarborDesign.Font.body)
                    .lineLimit(1)
                Text(subtitle)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(job?.state == .failed || error != nil ? AnyShapeStyle(HarborDesign.Surface.danger) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack(spacing: HarborDesign.Spacing.xxs) {
                if let job, !job.state.isFinal {
                    Button { hub.jobs.cancel(job) } label: { Image(systemName: "stop.fill") }
                        .help("Stop")
                        .accessibilityLabel("Stop \(recipe.name)")
                } else {
                    Button(action: run) { Image(systemName: "play.fill") }
                        .help("Run")
                        .accessibilityLabel("Run \(recipe.name)")
                }
            }
            .harborIconButtons()
        }
        .padding(.horizontal, HarborDesign.Spacing.md)
        .padding(.vertical, HarborDesign.Spacing.sm)
    }

    private func run() {
        do {
            error = nil
            _ = try AgentRecipeRunner.start(name: recipe.name, vars: [:], task: nil)
        } catch {
            self.error = error.agentMessage
        }
    }

    private var subtitle: String {
        if let error { return error }
        guard let job else {
            let sites = recipe.sites.joined(separator: ", ")
            return sites.isEmpty ? "\(recipe.steps.count) steps" : sites
        }
        switch job.state {
        case .running: return job.message ?? "Running"
        case .needsRepair: return "Needs a new target for a step; an agent can fix it"
        case .done: return "Done"
        case .failed: return job.error ?? "Failed"
        case .cancelled: return "Stopped"
        }
    }
}

struct AgentStatusDot: View {
    let status: AgentTask.Status

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: HarborDesign.Size.statusDot, height: HarborDesign.Size.statusDot)
            .accessibilityLabel(status.name)
    }

    private var color: Color {
        switch status {
        case .running: .green
        case .needsYou, .personControl: .orange
        case .done: .secondary
        case .failed: HarborDesign.Surface.danger
        case .stopped: .secondary
        }
    }
}

// MARK: - Card

/// One agent card: a symbol, a title and the task it is about, content, and buttons at the end.
private struct AgentCard<Content: View, Actions: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            HStack(spacing: HarborDesign.Spacing.md) {
                Image(systemName: symbol)
                    .font(HarborDesign.Font.title)
                    .foregroundStyle(HarborDesign.Surface.agentGradient)
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    Text(title)
                        .font(HarborDesign.Font.label)
                    Text(detail)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            content
            HStack(spacing: HarborDesign.Spacing.xxs) {
                Spacer(minLength: 0)
                actions
            }
            .buttonStyle(RectNavButtonStyle())
            .controlSize(.small)
        }
        .padding(HarborDesign.Spacing.lg)
        .frame(width: AgentOverlay.cardWidth, alignment: .leading)
        .harborFloatingSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
    }
}
