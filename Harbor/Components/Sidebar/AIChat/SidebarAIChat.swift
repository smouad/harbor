// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarAIChat.swift
//  Harbor
//
//  AI chat panel for sidebar — view-only layer delegating to AIService
//

import HarborSettings
import SwiftUI
import AppKit
import HarborDesign
import HarborWeb
import HarborUI

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: Role
    let content: String
    let timestamp: Date
    var citations: [URLCitation] = []
    var usedWebSearch: Bool = false

    enum Role {
        case user
        case assistant
    }
}

struct URLCitation: Identifiable, Equatable, Codable {
    var id = UUID()
    let url: String
    let title: String?
    let content: String?
    let startIndex: Int
    let endIndex: Int

    var displayTitle: String {
        title ?? url
    }

    var domain: String {
        if let urlObj = URL(string: url),
           let host = urlObj.host {
            return host.replacingOccurrences(of: "www.", with: "")
        }
        return url
    }
}

struct SidebarAIChat: View {
    @Environment(BrowserWindowState.self) private var windowState
    @EnvironmentObject var browserManager: BrowserManager
    @Environment(\.harborSettings) var harborSettings
    @Environment(AIService.self) var aiService
    @Environment(AIConfigService.self) var configService

    @State private var messageText: String = ""
    @State private var showAddModelPopover: Bool = false
    @State private var newModelId: String = ""
    @FocusState private var isTextFieldFocused: Bool

    private let streamingBubbleID = "streaming"

    var body: some View {
        VStack(spacing: 0) {
            // Messages area
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !aiService.hasApiKey {
                            apiKeyRequiredView
                        } else if aiService.messages.isEmpty {
                            emptyStateView
                        } else {
                            ForEach(aiService.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }
                        }

                        if aiService.isLoading {
                            if aiService.streamingText.isEmpty {
                                loadingView
                            } else {
                                MessageBubble(message: ChatMessage(role: .assistant, content: aiService.streamingText, timestamp: .now))
                                    .id(streamingBubbleID)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
                .onChange(of: aiService.streamingText) {
                    proxy.scrollTo(streamingBubbleID, anchor: .bottom)
                }
                .onChange(of: aiService.messages.count) { _, _ in
                    if let last = aiService.messages.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(stops: [.init(color: .black.opacity(0.2), location: 0.4), .init(color: .black, location: 1.0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 60)
                    Color.black
                    LinearGradient(colors: [.black, .black.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                        .frame(height: 90)
                }.ignoresSafeArea()
            }
        }
        .safeAreaInset(edge: .top, content: {
            headerView
        })
        .safeAreaInset(edge: .bottom) {
            inputAreaView
        }
        .safeAreaPadding(.top, 8)
        .safeAreaPadding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: windowState.agentDraft, initial: true) { takeAgentDraft() }
        .onAppear {
            isTextFieldFocused = true
            aiService.prepareACP(windowState: windowState)

            if configService.activeProviderType == .ollama {
                Task { await configService.fetchOllamaModels() }
            }
        }
        .onChange(of: aiService.messages.isEmpty) { _, isEmpty in
            // A cleared chat ended its agent session; start the next one before the next message
            if isEmpty { aiService.prepareACP(windowState: windowState) }
        }
        .onChange(of: configService.config.activeProviderId) { _, _ in
            aiService.prepareACP(windowState: windowState)
            if configService.activeProviderType == .ollama {
                Task { await configService.fetchOllamaModels() }
            }
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 8) {
            Button("Close", systemImage: "xmark") {
                withAnimation(HarborDesign.Motion.standard) {
                    windowState.isSidebarAIChatVisible = false
                }
            }
            .harborIconButtons()

            if !aiService.messages.isEmpty {
                Text("Ask Harbor")
                    .font(HarborDesign.Font.title)
                    .foregroundStyle(.primary)
                    .transition(.blur.animation(HarborDesign.Motion.standard))
            }

            Spacer()

            HStack(spacing: HarborDesign.Spacing.xxs) {
                Button("Settings", systemImage: "gearshape") {
                    showSettings()
                }
                Button("Clear Messages", systemImage: "trash") {
                    showClearMessagesDialog()
                }
                .disabled(aiService.messages.isEmpty)
            }
            .harborIconButtons()
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Input Area

    private var inputAreaView: some View {
        VStack(spacing: 8) {
            TextField("Ask about this page...", text: $messageText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(HarborDesign.Font.body)
                .foregroundStyle(.primary)
                .lineLimit(1...4)
                .focused($isTextFieldFocused)
                .onSubmit { sendMessage() }

            HStack(spacing: 8) {
                // Dynamic model selector
                modelSelectorMenu

                // Web search toggle
                if let providerType = configService.activeProviderType,
                   providerType == .gemini || providerType == .openRouter {
                    webSearchToggle
                }

                Spacer()

                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(HarborDesign.Font.titleLarge)
                        .foregroundStyle(messageText.isEmpty ? HierarchicalShapeStyle.tertiary : .primary)
                }
                .buttonStyle(.plain)
                .disabled(messageText.isEmpty || aiService.isLoading || !aiService.hasApiKey)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .padding(.horizontal, 8)
    }

    // MARK: - Model Selector

    private var modelSelectorMenu: some View {
        Menu {
            // The agents on this Mac first, each with the models and effort levels it offers
            ForEach(ACPClient.Preset.all, id: \.providerId) { preset in
                acpAgentMenu(preset)
            }

            Divider()

            // Providers with an API: pick one of their models
            ForEach(configService.providers.filter { !$0.providerType.isACP && $0.isEnabled }) { provider in
                Menu(provider.displayName) {
                    let models = configService.modelsForProvider(provider.id)
                    if models.isEmpty {
                        Text("No models added")
                    }
                    ForEach(models) { model in
                        Button {
                            configService.setActiveProvider(provider.id)
                            configService.setActiveModel(model.id)
                        } label: {
                            checkRow(model.displayName, checked: configService.config.activeProviderId == provider.id && configService.config.activeModelId == model.id)
                        }
                    }
                }
            }

            // Show fetched dynamic models if available
            if !configService.ollamaModels.isEmpty && configService.activeProviderType == .ollama {
                Divider()
                ForEach(configService.ollamaModels) { model in
                    Button(action: {
                        configService.addModel(model)
                        configService.setActiveModel(model.id)
                    }) {
                        checkRow(model.displayName, checked: configService.config.activeModelId == model.id)
                    }
                }
            }

            Divider()

            if configService.activeProviderType?.isACP != true {
                Button(action: { showAddModelPopover = true }) {
                    Label("Add Model...", systemImage: "plus.circle")
                }
            }

            Button(action: { showSettings() }) {
                Label("Manage Models...", systemImage: "gearshape")
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectorTitle)
                if let type = configService.activeProviderType, aiService.acpStarting == type {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(RectNavButtonStyle())
        .controlSize(.small)
        .popover(isPresented: $showAddModelPopover, arrowEdge: .top) {
            VStack(spacing: 8) {
                Text("Add Model by ID")
                    .font(HarborDesign.Font.secondary)
                TextField("Model ID (e.g. gpt-4o)", text: $newModelId)
                    .textFieldStyle(.roundedBorder)
                    .font(HarborDesign.Font.secondary)
                    .frame(width: 200)
                HStack {
                    Button("Cancel") {
                        newModelId = ""
                        showAddModelPopover = false
                    }
                    .controlSize(.small)
                    Button("Add") {
                        guard !newModelId.isEmpty,
                              let providerId = configService.config.activeProviderId else { return }
                        configService.addModelById(newModelId, displayName: nil, providerId: providerId)
                        configService.setActiveModel(newModelId)
                        newModelId = ""
                        showAddModelPopover = false
                    }
                    .controlSize(.small)
                    .disabled(newModelId.isEmpty || configService.config.activeProviderId == nil)
                }
            }
            .padding(12)
        }
    }

    /// "Claude · Opus 5.5": the agent or provider, then its model.
    private var selectorTitle: String {
        guard let type = configService.activeProviderType else { return "Choose a Model" }
        if type.isACP {
            let model = aiService.acpOptions[type]?.first { $0.category == "model" }
            return model.map { "\(type.displayName) · \($0.currentName)" } ?? type.displayName
        }
        return configService.activeModel?.displayName ?? "Add Model"
    }

    /// One agent: its models and reasoning levels once a session has reported them, else just the agent.
    @ViewBuilder
    private func acpAgentMenu(_ preset: ACPClient.Preset) -> some View {
        let active = configService.activeProviderType == preset.type
        let options = (aiService.acpOptions[preset.type] ?? []).filter { $0.category == "model" || $0.category == "thought_level" }
        if options.isEmpty {
            Button { chooseAgent(preset.type) } label: { checkRow(preset.type.displayName, checked: active) }
        } else {
            Menu {
                Button { chooseAgent(preset.type) } label: { checkRow("Use \(preset.type.displayName)", checked: active) }
                ForEach(options) { option in
                    Section(option.category == "model" ? "Model" : option.name) {
                        ForEach(option.choices) { choice in
                            Button { chooseAgent(preset.type, option: option.id, value: choice.value) } label: {
                                checkRow(choice.name, checked: choice.value == option.currentValue)
                            }
                        }
                    }
                }
            } label: {
                checkRow(preset.type.displayName, checked: active)
            }
        }
    }

    private func chooseAgent(_ type: AIProviderType, option: String? = nil, value: String? = nil) {
        Task { await aiService.selectACP(type, option: option, value: value, windowState: windowState) }
    }

    private func checkRow(_ title: String, checked: Bool) -> some View {
        HStack {
            Text(title)
            if checked {
                Spacer()
                Image(systemName: "checkmark")
            }
        }
    }

    // MARK: - Web Search Toggle

    private var webSearchToggle: some View {
        Button(action: {
            withAnimation(HarborDesign.Motion.standard) {
                var config = configService.generationConfig
                config.webSearchEnabled.toggle()
                configService.generationConfig = config
            }
        }) {
            Image(systemName: configService.generationConfig.webSearchEnabled ? "globe.americas.fill" : "globe")
                .foregroundStyle(configService.generationConfig.webSearchEnabled ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(HarborIconButtonStyle())
        .help(configService.generationConfig.webSearchEnabled ? "Web Search On" : "Web Search Off")
    }

    // MARK: - Empty/Loading States

    private var apiKeyRequiredView: some View {
        VStack(spacing: 12) {
            Image(systemName: "key.fill")
                .font(HarborDesign.Font.display)
                .foregroundStyle(.tertiary)

            Text("API Key Required")
                .font(HarborDesign.Font.label)
                .foregroundStyle(.primary)

            Text("Add your API key to start chatting")
                .font(HarborDesign.Font.secondary)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Add API Key") { showSettings() }
                .font(HarborDesign.Font.secondary)
                .buttonStyle(RectNavButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            let webSearchEnabled = configService.generationConfig.webSearchEnabled
            let supportsWebSearch = configService.activeProviderType == .openRouter || configService.activeProviderType == .gemini

            Image(systemName: webSearchEnabled && supportsWebSearch ? "globe" : "sparkle")
                .font(HarborDesign.Font.display)
                .foregroundStyle(webSearchEnabled && supportsWebSearch ? AnyShapeStyle(.green.opacity(0.6)) : AnyShapeStyle(.tertiary))

            Text("Ask Harbor")
                .font(HarborDesign.Font.label)
                .foregroundStyle(.primary)

            if webSearchEnabled && supportsWebSearch {
                VStack(spacing: 6) {
                    Text("Questions about this page, or just curious? I'm here.")
                        .font(HarborDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.green.opacity(0.7))
                        Text("Web search enabled")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.green.opacity(0.7))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.12))
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
                }
            } else {
                Text("Questions about this page, or just curious? I'm here.")
                    .font(HarborDesign.Font.secondary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 60)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.7)
            VStack(alignment: .leading, spacing: 2) {
                if let toolName = aiService.currentToolName {
                    Text("Using \(toolName)...")
                        .font(HarborDesign.Font.secondary)
                        .foregroundStyle(.purple.opacity(0.8))
                } else {
                    Text("Thinking...")
                        .font(HarborDesign.Font.secondary)
                        .foregroundStyle(.secondary)
                }
                if configService.generationConfig.webSearchEnabled && !aiService.isExecutingTools {
                    Text("Searching the web...")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - Actions

    private func sendMessage() {
        guard !messageText.isEmpty, aiService.hasApiKey else { return }
        let text = messageText
        messageText = ""
        Task {
            await aiService.sendMessage(text, windowState: windowState)
        }
    }

    private func takeAgentDraft() {
        guard let draft = windowState.agentDraft else { return }
        windowState.agentDraft = nil
        messageText = messageText.isEmpty ? draft : messageText + "\n\n" + draft
        isTextFieldFocused = true
    }

    private func showSettings() {
        browserManager.openSettings(tab: .ai)
    }

    private func showClearMessagesDialog() {
        browserManager.dialogManager.showDialog {
            StandardDialog(
                header: {
                    DialogHeader(
                        icon: "trash.fill",
                        title: "Clear Chat History?",
                        subtitle: "This will delete all messages in this conversation"
                    )
                },
                content: {
                    EmptyView()
                },
                footer: {
                    DialogFooter(
                        rightButtons: [
                            DialogButton(
                                text: "Cancel",
                                variant: .secondary,
                                action: {
                                    browserManager.dialogManager.closeDialog()
                                }
                            ),
                            DialogButton(
                                text: "Clear",
                                iconName: "trash",
                                variant: .primary,
                                action: {
                                    withAnimation(HarborDesign.Motion.standard) {
                                        aiService.clearMessages()
                                    }
                                    browserManager.dialogManager.closeDialog()
                                }
                            )
                        ]
                    )
                }
            )
        }
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: ChatMessage
    @EnvironmentObject var gradientColorManager: GradientColorManager
    @Environment(BrowserWindowState.self) private var windowState
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) var openURL
    @State private var isHovered: Bool = false
    @State private var showCopied: Bool = false

    /// The person's own messages carry the space's accent; private windows keep the neutral one.
    private var accent: Color {
        windowState.isIncognito ? SpaceGradient.incognito.primaryColor : gradientColorManager.accentColor
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == .user {
                Spacer(minLength: 40)
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                if message.role == .assistant {
                    VStack(alignment: .leading, spacing: 0) {
                        if message.usedWebSearch {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(HarborDesign.Font.caption)
                                Text("Web Search")
                                    .font(HarborDesign.Font.caption)
                                if !message.citations.isEmpty {
                                    Text("• \(message.citations.count) \(message.citations.count == 1 ? "source" : "sources")")
                                        .font(HarborDesign.Font.caption)
                                }
                            }
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.green.opacity(0.15))
                            .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.sm))
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 6)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(parseMarkdown(message.content).enumerated()), id: \.offset) { _, block in
                                block
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.top, message.usedWebSearch ? 6 : 10)
                        .padding(.bottom, message.citations.isEmpty ? 10 : 6)

                        if !message.citations.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Divider()
                                    .padding(.horizontal, 12)

                                Text("Sources")
                                    .font(HarborDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)

                                VStack(spacing: 4) {
                                    ForEach(message.citations) { citation in
                                        CitationView(citation: citation)
                                    }
                                }
                                .padding(.horizontal, 12)
                            }
                            .padding(.bottom, 10)
                        }
                    }
                    .harborControlSurface(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
                    .overlay(alignment: .topTrailing) {
                        if isHovered {
                            Button(action: {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(message.content, forType: .string)
                                showCopied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    showCopied = false
                                }
                            }) {
                                Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                    .font(HarborDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 28, height: 28)
                                    // Raised so it stands off the bubble's fill
                                    .background(
                                        HarborDesign.Radius.shape(HarborDesign.Radius.md)
                                            .fill(HarborDesign.Surface.raised)
                                    )
                                    .overlay(
                                        HarborDesign.Radius.shape(HarborDesign.Radius.md)
                                            .strokeBorder(HarborDesign.Surface.hairline, lineWidth: HarborDesign.Size.hairlineWidth)
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                } else {
                    Text(message.content)
                        .font(HarborDesign.Font.bodyRegular)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .harborControlSurface(tint: accent, in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
                }
            }

            if message.role == .assistant {
                Spacer(minLength: 40)
            }
        }
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovered = hovering
            }
        }
    }

    private func parseMarkdown(_ content: String) -> [AnyView] {
        var views: [AnyView] = []
        let lines = content.components(separatedBy: .newlines)
        var i = 0
        var inCodeBlock = false
        var codeBlockContent: [String] = []
        var codeBlockLanguage: String = ""

        while i < lines.count {
            let line = lines[i]

            if line.hasPrefix("```") {
                if inCodeBlock {
                    let code = codeBlockContent.joined(separator: "\n")
                    views.append(AnyView(codeBlockView(code, language: codeBlockLanguage)))
                    codeBlockContent = []
                    codeBlockLanguage = ""
                    inCodeBlock = false
                } else {
                    inCodeBlock = true
                    codeBlockLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                i += 1
                continue
            }

            if inCodeBlock {
                codeBlockContent.append(line)
                i += 1
                continue
            }

            if line.hasPrefix("### ") {
                views.append(AnyView(headerView(String(line.dropFirst(4)), level: 3)))
            } else if line.hasPrefix("## ") {
                views.append(AnyView(headerView(String(line.dropFirst(3)), level: 2)))
            } else if line.hasPrefix("# ") {
                views.append(AnyView(headerView(String(line.dropFirst(2)), level: 1)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                views.append(AnyView(bulletView(String(line.dropFirst(2)))))
            } else if line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil {
                let text = line.replacingOccurrences(of: #"^\d+\.\s"#, with: "", options: .regularExpression)
                views.append(AnyView(numberedView(text)))
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                views.append(AnyView(paragraphView(line)))
            }

            i += 1
        }

        return views
    }

    private func headerView(_ text: String, level: Int) -> some View {
        let fontSize: CGFloat = level == 1 ? 17 : level == 2 ? 15 : 14
        let weight: Font.Weight = level == 1 ? .bold : level == 2 ? .semibold : .medium

        return Text(parseInlineMarkdown(text))
            .font(.system(size: fontSize, weight: weight))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 2)
    }

    private func paragraphView(_ text: String) -> some View {
        Text(parseInlineMarkdown(text))
            .font(HarborDesign.Font.bodyRegular)
            .lineSpacing(4)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bulletView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(HarborDesign.Font.body)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(parseInlineMarkdown(text))
                .font(HarborDesign.Font.bodyRegular)
                .lineSpacing(4)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func numberedView(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
                .font(HarborDesign.Font.body)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            Text(parseInlineMarkdown(text))
                .font(HarborDesign.Font.bodyRegular)
                .lineSpacing(4)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func codeBlockView(_ code: String, language: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !language.isEmpty {
                Text(language)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(HarborDesign.Surface.fill)
                    .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.xs))
            }
            Text(code)
                .font(HarborDesign.Font.secondary.monospaced())
                .foregroundStyle(.primary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(HarborDesign.Surface.fillPressed)
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
        }
    }

    private func parseInlineMarkdown(_ text: String) -> AttributedString {
        do {
            return try AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        } catch {
            return AttributedString(text)
        }
    }
}

// MARK: - Citation View

struct CitationView: View {
    let citation: URLCitation
    @Environment(\.openURL) var openURL
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let url = URL(string: citation.url) {
                openURL(url)
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: "link")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.tertiary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.domain)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(isHovered ? .primary : .secondary)
                        .lineLimit(1)

                    if let title = citation.title, !title.isEmpty {
                        Text(title)
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(isHovered ? .secondary : .tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                HarborDesign.Radius.shape(HarborDesign.Radius.sm)
                    .fill(isHovered ? HarborDesign.Surface.fillPressed : HarborDesign.Surface.fill)
            )
            .overlay(
                HarborDesign.Radius.shape(HarborDesign.Radius.sm)
                    .stroke(isHovered ? HarborDesign.Surface.hairline : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHoverTracking { hovering in
            withAnimation(HarborDesign.Motion.quick) {
                isHovered = hovering
            }
        }
    }
}
