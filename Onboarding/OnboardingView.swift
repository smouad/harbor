// Licensed under GPL-3.0. See LICENSE.
//
//  OnboardingView.swift
//  Harbor
//
//  First run, laid out the way Arc and Dia lay theirs out: one card per step over a grainy
//  gradient in the space's color, words on the left, a live picture of the choice on the right,
//  and Return pressing the main button. No account, nothing privacy-costly chosen for the
//  person, and Return never starts an import.
//

import HarborDesign
import HarborSettings
import HarborUI
import HarborWeb
import SwiftUI

struct OnboardingView: View {
    @Environment(\.harborSettings) var harborSettings
    @Environment(TabsController.self) private var tabs
    @EnvironmentObject var browserManager: BrowserManager

    private enum Stage: Int, CaseIterable {
        case hello, importData, spaces, layout, blocking, agent, defaultBrowser, done
    }

    @State private var stage: Stage = .hello
    @State private var selectedBrowser: Browsers?
    @State private var isLoading: Bool = false
    @State private var showSafariImportFlow: Bool = false
    /// The color the whole flow is drawn in: the first space's, or Harbor's default teal while
    /// that space still has the starter grey.
    @State private var accentHex: String = SpaceAccent.defaultHex
    @State private var isAlreadyDefault = DefaultBrowserStage.isDefault
    /// Claude and Codex found on this Mac, looked up as the flow opens; nil until known.
    @State private var installedAgents: [ACPClient.Preset]?
    @State private var agentChoice: AIProviderType?

    var body: some View {
        ZStack {
            background
            if showSafariImportFlow {
                SafariImportFlow(
                    isLoading: $isLoading,
                    onBack: {
                        withAnimation(HarborDesign.Motion.standard) { showSafariImportFlow = false }
                    },
                    onComplete: {
                        withAnimation(HarborDesign.Motion.standard) { showSafariImportFlow = false }
                        go(to: .spaces)
                    }
                )
                .padding(HarborDesign.Spacing.xxxl)
                .transition(.slideAndBlur)
            } else {
                card
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .preferredColorScheme(colorScheme)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.return) {
            guard !isLoading, !showSafariImportFlow, isPrimaryEnabled else { return .ignored }
            advance()
            return .handled
        }
        .onAppear(perform: refreshAccent)
        .task {
            let found = await ACPClient.Preset.installed()
            installedAgents = found
            if found.count == 1 { agentChoice = found.first?.type }
        }
    }

    // MARK: - Layout

    private var background: some View {
        let accent = Color(hex: accentHex)
        return ZStack {
            LinearGradient(
                colors: [accent.mix(with: HarborDesign.Brand.deepNavy, by: 0.45), HarborDesign.Brand.deepNavy],
                startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [accent.opacity(0.35), .clear],
                center: .top, startRadius: 0, endRadius: 640)
            HarborGrain()
        }
        .ignoresSafeArea()
        .animation(HarborDesign.Motion.standard, value: accentHex)
    }

    private var card: some View {
        let shape = HarborDesign.Radius.shape(HarborDesign.Radius.xl)
        return ZStack(alignment: .topLeading) {
            stageView
                .id(stage)
                .transition(.onboardingStep)

            if stage != .hello && !isLoading {
                Button("Back", systemImage: "chevron.left", action: goBack)
                    .buttonStyle(.plain)
                    .font(HarborDesign.Font.body)
                    .foregroundStyle(.secondary)
                    .frame(height: OnboardingMetrics.backRowHeight)
                    .padding(.leading, OnboardingMetrics.cardPadding)
                    .padding(.top, OnboardingMetrics.cardPadding - HarborDesign.Spacing.md)
            }

            StageFooter(
                primaryTitle: primaryTitle,
                accentHex: accentHex,
                isPrimaryEnabled: isPrimaryEnabled,
                isLoading: isLoading,
                secondaryTitle: secondaryTitle,
                onPrimary: advance,
                onSecondary: skip
            )
            .padding(.leading, OnboardingMetrics.cardPadding)
            .padding(.bottom, OnboardingMetrics.cardPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)

            StageIndicator(stages: Stage.allCases.count, activeStage: stage.rawValue, accentHex: accentHex)
        }
        .frame(width: OnboardingMetrics.cardSize.width, height: OnboardingMetrics.cardSize.height)
        .background(HarborDesign.Surface.raised)
        .clipShape(shape)
        .overlay(shape.strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth))
        .shadow(color: .black.opacity(0.4), radius: 40, y: 20)
    }

    @ViewBuilder
    private var stageView: some View {
        let addressOnTop = harborSettings.topBarAddressView
        switch stage {
        case .hello: HelloStage(accentHex: accentHex, addressOnTop: addressOnTop)
        case .importData: ImportStage(selectedBrowser: $selectedBrowser, accentHex: accentHex)
        case .spaces: SpacesStage(accentHex: $accentHex)
        case .layout: LayoutStage(accentHex: accentHex)
        case .blocking: BlockingStage(accentHex: accentHex)
        case .agent: AgentStage(accentHex: accentHex, installed: installedAgents, choice: $agentChoice)
        case .defaultBrowser: DefaultBrowserStage(accentHex: accentHex, addressOnTop: addressOnTop)
        case .done: FinalStage(accentHex: accentHex)
        }
    }

    private var colorScheme: ColorScheme? {
        switch harborSettings.appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    // MARK: - Footer

    private var primaryTitle: String {
        switch stage {
        case .hello: return "Get started"
        case .importData:
            if isLoading { return "Importing…" }
            return selectedBrowser.map { "Import from \($0.name)" } ?? "Import"
        case .spaces, .layout, .blocking: return "Continue"
        case .agent:
            guard let found = installedAgents, !found.isEmpty else { return "Continue" }
            return agentChoice.map { "Use \($0.displayName)" } ?? "Choose an agent"
        case .defaultBrowser: return isAlreadyDefault ? "Continue" : "Make Harbor default"
        case .done: return "Start browsing"
        }
    }

    private var isPrimaryEnabled: Bool {
        switch stage {
        case .importData: return selectedBrowser != nil
        case .agent:
            // With both agents the person picks one; with one or none there is nothing to choose
            guard let found = installedAgents else { return false }
            return found.count < 2 || agentChoice != nil
        default: return true
        }
    }

    private var secondaryTitle: String? {
        switch stage {
        case .hello: return "Skip setup"
        case .importData: return "Start fresh"
        case .agent: return installedAgents?.isEmpty == false ? "Not now" : nil
        case .defaultBrowser: return isAlreadyDefault ? nil : "Not now"
        default: return nil
        }
    }

    // MARK: - Steps

    private func advance() {
        switch stage {
        case .hello:
            go(to: .importData)
        case .importData:
            guard let browser = selectedBrowser else { return }
            if browser == .safari {
                withAnimation(HarborDesign.Motion.standard) { showSafariImportFlow = true }
                return
            }
            withAnimation(HarborDesign.Motion.standard) { isLoading = true }
            performImport(browser) {
                isLoading = false
                refreshAccent()
                go(to: .spaces)
            }
        case .spaces:
            go(to: .layout)
        case .layout:
            go(to: .blocking)
        case .blocking:
            go(to: .agent)
        case .agent:
            useChosenAgent()
            go(to: .defaultBrowser)
        case .defaultBrowser:
            if isAlreadyDefault {
                go(to: .done)
            } else {
                DefaultBrowserStage.setAsDefault {
                    isAlreadyDefault = DefaultBrowserStage.isDefault
                    go(to: .done)
                }
            }
        case .done:
            finish()
        }
    }

    private func skip() {
        if stage == .hello {
            finish()
            return
        }
        guard let next = Stage(rawValue: stage.rawValue + 1) else { return }
        go(to: next)
    }

    private func goBack() {
        guard let previous = Stage(rawValue: stage.rawValue - 1) else { return }
        go(to: previous)
    }

    private func go(to next: Stage) {
        withAnimation(HarborDesign.Motion.standard) { stage = next }
    }

    /// Makes the chosen agent the AI Assistant's and shows the Assistant, which is hidden until an
    /// agent or provider is set up.
    private func useChosenAgent() {
        guard let choice = agentChoice, let preset = ACPClient.Preset.of(choice) else { return }
        browserManager.aiConfigService?.setActiveProvider(preset.providerId)
        harborSettings.showAIAssistant = true
    }

    private func finish() {
        harborSettings.didFinishOnboarding = true
    }

    /// Takes the first space's color, unless it still has the starter grey.
    private func refreshAccent() {
        guard let first = tabs.orderedSpaces.first(where: { $0.id != tabs.agentSpaceID }) else { return }
        if first.accentHex.caseInsensitiveCompare("#7C7C7C") != .orderedSame {
            accentHex = first.accentHex
        }
    }

    private func performImport(_ browser: Browsers, completion: @escaping () -> Void) {
        Task {
            switch browser {
            case .arc:
                await browserManager.importArcData()
            case .dia:
                await browserManager.importDiaData()
            default:
                break
            }
            await MainActor.run { completion() }
        }
    }
}
