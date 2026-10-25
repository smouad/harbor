// Licensed under GPL-3.0. See LICENSE.
//
//  AI.swift
//  Harbor
//
//  AI settings — flat Form layout matching other settings tabs
//

import HarborSettings
import SwiftUI
import HarborDesign

struct SettingsAITab: View {
    @Environment(\.harborSettings) var harborSettings
    @Environment(AIConfigService.self) var configService
    @Environment(MCPManager.self) var mcpManager

    @State private var openRouterSearch: String = ""
    @State private var testingConnection: Bool = false
    @State private var connectionTestResult: String?
    @State private var newMCPServerName: String = ""
    @State private var newMCPServerCommand: String = ""
    @State private var newMCPServerArgs: String = ""
    @State private var showAddMCPServer: Bool = false
    @State private var showAddCustomProvider: Bool = false
    @State private var customProviderName: String = ""
    @State private var customProviderURL: String = ""
    @State private var customProviderKey: String = ""
    @State private var addModelId: String = ""
    @State private var showFetchedModels: Bool = false

    var body: some View {
        @Bindable var settings = harborSettings
        Form {
            // MARK: - Tab Organizer
            Section {
                if let note = TabOrganizationModel.unavailableNote {
                    Text(note)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: $settings.tabOrganizerEnabled) {
                        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                            Text("Tab Organizer")
                                .font(HarborDesign.Font.body)
                            Text("Uses Apple Intelligence on this Mac to group, rename, sort, and deduplicate tabs")
                                .font(HarborDesign.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $settings.autoRenamePinnedTabs) {
                        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                            Text("Rename Pinned Tabs")
                                .font(HarborDesign.Font.body)
                            Text("Shortens a tab's title when you pin it to a space")
                                .font(HarborDesign.Font.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Tab Organizer")
            } footer: {
                if harborSettings.tabOrganizerEnabled, TabOrganizationModel.unavailableNote == nil {
                    Text("Right-click a space or press \u{2318}\u{21E7}\u{2325}O to organize tabs")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            // MARK: - Providers
            Section("Providers") {
                ForEach(configService.providers) { provider in
                    providerRow(provider)
                }

                if showAddCustomProvider {
                    VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
                        TextField("Provider Name", text: $customProviderName)
                        TextField("Base URL (e.g., http://localhost:1234/v1)", text: $customProviderURL)
                        SecureField("API Key (optional)", text: $customProviderKey)
                        HStack {
                            Button("Cancel") {
                                showAddCustomProvider = false
                                customProviderName = ""
                                customProviderURL = ""
                                customProviderKey = ""
                            }
                            Button("Add") {
                                configService.addCustomProvider(
                                    name: customProviderName,
                                    baseURL: customProviderURL,
                                    apiKey: customProviderKey
                                )
                                showAddCustomProvider = false
                                customProviderName = ""
                                customProviderURL = ""
                                customProviderKey = ""
                            }
                            .disabled(customProviderName.isEmpty || customProviderURL.isEmpty)
                        }
                    }
                } else {
                    Button(action: { showAddCustomProvider = true }) {
                        Label("Add Custom Provider", systemImage: "plus.circle")
                    }
                }
            }

            // MARK: - Models
            Section("Models") {
                if configService.models.isEmpty {
                    Text("No models added. Add a model by ID or fetch from a provider.")
                        .foregroundStyle(.secondary)
                        .font(HarborDesign.Font.secondary)
                }

                ForEach(configService.models) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                            Text(model.displayName)
                                .font(HarborDesign.Font.secondary)
                            Text(model.id)
                                .font(HarborDesign.Font.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()

                        if configService.config.activeModelId == model.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(HarborDesign.Font.body)
                        }

                        Button(action: { configService.setActiveModel(model.id) }) {
                            Text(configService.config.activeModelId == model.id ? "Active" : "Use")
                                .font(HarborDesign.Font.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(configService.config.activeModelId == model.id)

                        Button(action: {
                            configService.removeModel(model.id, providerId: model.providerId)
                        }) {
                            Image(systemName: "trash")
                                .font(HarborDesign.Font.caption)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                }

                // Add by ID
                HStack {
                    TextField("Add model by ID (e.g., gpt-4o)", text: $addModelId)
                        .textFieldStyle(.roundedBorder)
                        .font(HarborDesign.Font.secondary)
                    Button("Add") {
                        guard !addModelId.isEmpty,
                              let providerId = configService.config.activeProviderId else { return }
                        configService.addModelById(addModelId, displayName: nil, providerId: providerId)
                        addModelId = ""
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(addModelId.isEmpty || configService.config.activeProviderId == nil)
                }

                // Fetch from provider
                if configService.activeProviderType == .openRouter {
                    DisclosureGroup("Fetch from OpenRouter", isExpanded: $showFetchedModels) {
                        HStack {
                            TextField("Search models...", text: $openRouterSearch)
                                .textFieldStyle(.roundedBorder)
                                .font(HarborDesign.Font.secondary)
                            Button("Fetch") {
                                Task {
                                    await configService.fetchOpenRouterModels(search: openRouterSearch.isEmpty ? nil : openRouterSearch)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(configService.isFetchingModels)
                        }

                        if configService.isFetchingModels {
                            HStack {
                                ProgressView().scaleEffect(0.7)
                                Text("Loading models...")
                                    .font(HarborDesign.Font.secondary)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(configService.openRouterModels.prefix(50)) { model in
                            fetchedModelRow(model)
                        }
                    }
                }

                if configService.activeProviderType == .ollama {
                    DisclosureGroup("Fetch from Ollama", isExpanded: $showFetchedModels) {
                        Button("Refresh") {
                            Task { await configService.fetchOllamaModels() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(configService.isFetchingModels)

                        if configService.isFetchingModels {
                            HStack {
                                ProgressView().scaleEffect(0.7)
                                Text("Loading models...")
                                    .font(HarborDesign.Font.secondary)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        ForEach(configService.ollamaModels) { model in
                            fetchedModelRow(model)
                        }
                    }
                }
            }

            // MARK: - Generation
            Section("Generation") {
                // Temperature
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", configService.generationConfig.temperature))
                            .font(HarborDesign.Font.secondary.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { configService.generationConfig.temperature },
                            set: {
                                var config = configService.generationConfig
                                config.temperature = $0
                                configService.generationConfig = config
                            }
                        ),
                        in: 0...2,
                        step: 0.1
                    )
                    Text("Lower = more focused, Higher = more creative")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }

                // Max tokens
                HStack {
                    Text("Max Output Tokens")
                    Spacer()
                    TextField("4096", value: Binding(
                        get: { configService.generationConfig.maxTokens },
                        set: {
                            var config = configService.generationConfig
                            config.maxTokens = $0
                            configService.generationConfig = config
                        }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: HarborDesign.Size.fieldNarrow)
                }

                // System prompt
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xs) {
                    HStack {
                        Text("System Prompt")
                        Spacer()
                        Button("Reset to Default") {
                            var config = configService.generationConfig
                            config.systemPrompt = AIGenerationConfig.defaultSystemPrompt
                            configService.generationConfig = config
                        }
                        .font(HarborDesign.Font.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    TextEditor(text: Binding(
                        get: { configService.generationConfig.systemPrompt },
                        set: {
                            var config = configService.generationConfig
                            config.systemPrompt = $0
                            configService.generationConfig = config
                        }
                    ))
                    .font(HarborDesign.Font.secondary)
                    .frame(height: HarborDesign.Size.textEditorHeight)
                    .border(.quaternary)
                }

                // Streaming
                Toggle("Enable Streaming", isOn: Binding(
                    get: { configService.generationConfig.streamingEnabled },
                    set: {
                        var config = configService.generationConfig
                        config.streamingEnabled = $0
                        configService.generationConfig = config
                    }
                ))

                // Web search
                Toggle("Web Search", isOn: Binding(
                    get: { configService.generationConfig.webSearchEnabled },
                    set: {
                        var config = configService.generationConfig
                        config.webSearchEnabled = $0
                        configService.generationConfig = config
                    }
                ))

                if configService.generationConfig.webSearchEnabled {
                    Picker("Engine", selection: Binding(
                        get: { configService.generationConfig.webSearchEngine },
                        set: {
                            var config = configService.generationConfig
                            config.webSearchEngine = $0
                            configService.generationConfig = config
                        }
                    )) {
                        Text("Auto").tag("auto")
                        Text("Native").tag("native")
                        Text("Exa").tag("exa")
                    }
                    .pickerStyle(.segmented)

                    Picker("Context Size", selection: Binding(
                        get: { configService.generationConfig.webSearchContextSize },
                        set: {
                            var config = configService.generationConfig
                            config.webSearchContextSize = $0
                            configService.generationConfig = config
                        }
                    )) {
                        Text("Low").tag("low")
                        Text("Medium").tag("medium")
                        Text("High").tag("high")
                    }
                    .pickerStyle(.segmented)

                    Picker("Max Results", selection: Binding(
                        get: { configService.generationConfig.webSearchMaxResults },
                        set: {
                            var config = configService.generationConfig
                            config.webSearchMaxResults = $0
                            configService.generationConfig = config
                        }
                    )) {
                        Text("3").tag(3)
                        Text("5").tag(5)
                        Text("10").tag(10)
                    }
                    .pickerStyle(.segmented)
                }
            }

            // MARK: - Browser Tools
            Section("Browser Tools") {
                Picker("Execution Mode", selection: Binding(
                    get: { configService.browserToolsConfig.executionMode },
                    set: {
                        var config = configService.browserToolsConfig
                        config.executionMode = $0
                        configService.browserToolsConfig = config
                    }
                )) {
                    ForEach(BrowserToolExecutionMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ForEach(Array(BrowserToolsConfig.allToolNames.sorted()), id: \.self) { toolName in
                    Toggle(isOn: Binding(
                        get: { configService.browserToolsConfig.enabledTools.contains(toolName) },
                        set: { enabled in
                            var config = configService.browserToolsConfig
                            if enabled {
                                config.enabledTools.insert(toolName)
                            } else {
                                config.enabledTools.remove(toolName)
                            }
                            configService.browserToolsConfig = config
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(toolName)
                                .font(HarborDesign.Font.secondary)
                            if let tool = BrowserTools.toolsByName[toolName] {
                                Text(tool.description)
                                    .font(HarborDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            // MARK: - MCP Servers
            Section("MCP Servers") {
                if configService.mcpServers.isEmpty && !showAddMCPServer {
                    VStack(spacing: HarborDesign.Spacing.md) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(HarborDesign.Font.titleLarge)
                            .foregroundStyle(.secondary)
                        Text("No MCP servers configured")
                            .font(HarborDesign.Font.body)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, HarborDesign.Spacing.lg)
                }

                ForEach(configService.mcpServers) { server in
                    mcpServerRow(server)
                }

                if showAddMCPServer {
                    addMCPServerForm
                } else {
                    Button(action: { showAddMCPServer = true }) {
                        Label("Add Server", systemImage: "plus.circle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Provider Row

    @ViewBuilder
    private func providerRow(_ provider: AIProviderConfig) -> some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    HStack(spacing: HarborDesign.Spacing.sm) {
                        Text(provider.displayName)
                            .font(HarborDesign.Font.label)

                        if configService.config.activeProviderId == provider.id {
                            Text("Active")
                                .font(HarborDesign.Font.caption)
                                .foregroundStyle(.green)
                                .padding(.horizontal, HarborDesign.Spacing.sm)
                                .padding(.vertical, HarborDesign.Spacing.xxs)
                                .background(HarborDesign.Radius.shape(HarborDesign.Radius.xs).fill(.green.opacity(0.15)))
                        }
                    }

                    Text(provider.providerType.isACP
                         ? "Uses the \(provider.providerType.displayName) installed on this Mac and its sign-in, over ACP"
                         : provider.providerType.displayName)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { newValue in
                        var updated = provider
                        updated.isEnabled = newValue
                        configService.updateProvider(updated)
                    }
                ))

                if configService.config.activeProviderId != provider.id {
                    Button("Use") {
                        configService.setActiveProvider(provider.id)
                    }
                    .font(HarborDesign.Font.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if provider.providerType.requiresAPIKey {
                HStack(spacing: HarborDesign.Spacing.md) {
                    SecureField("API Key", text: Binding(
                        get: { provider.apiKey },
                        set: { newValue in
                            // Update provider config and API key separately
                            configService.updateProvider(provider, apiKey: newValue)
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(HarborDesign.Font.secondary)

                    if !provider.apiKey.isEmpty {
                        Button("Test") {
                            testConnection(provider)
                        }
                        .font(HarborDesign.Font.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(testingConnection)
                    }
                }
            }

            if provider.providerType == .ollama || provider.providerType == .openAICompatible {
                TextField("Base URL", text: Binding(
                    get: { provider.baseURL },
                    set: { newValue in
                        var updated = provider
                        updated.baseURL = newValue
                        configService.updateProvider(updated)
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .font(HarborDesign.Font.secondary)
            }

            if let result = connectionTestResult {
                Text(result)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(result.contains("Success") ? .green : .red)
            }
        }
    }

    // MARK: - Fetched Model Row

    @ViewBuilder
    private func fetchedModelRow(_ model: AIModelConfig) -> some View {
        let alreadyAdded = configService.models.contains { $0.id == model.id && $0.providerId == model.providerId }
        HStack {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(model.displayName)
                    .font(HarborDesign.Font.secondary)
                Text(model.id)
                    .font(HarborDesign.Font.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if alreadyAdded {
                Text("Added")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button("Add") {
                    configService.addModel(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: - MCP Server Row

    @ViewBuilder
    private func mcpServerRow(_ server: MCPServerConfig) -> some View {
        let state = mcpManager.connectionState(for: server.id)
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            HStack {
                VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                    Text(server.name)
                        .font(HarborDesign.Font.label)

                    switch server.transport {
                    case .stdio(let cmd, let args):
                        Text("\(cmd) \(args.joined(separator: " "))")
                            .font(HarborDesign.Font.caption.monospaced())
                            .foregroundStyle(.secondary)
                    case .sse(let url):
                        Text(url)
                            .font(HarborDesign.Font.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: HarborDesign.Spacing.xs) {
                    Circle()
                        .fill(stateColor(state))
                        .frame(width: HarborDesign.Size.statusDot, height: HarborDesign.Size.statusDot)
                    Text(state.displayName)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("", isOn: Binding(
                    get: { server.isEnabled },
                    set: { newValue in
                        var updated = server
                        updated.isEnabled = newValue
                        configService.updateMCPServer(updated)
                        if newValue {
                            mcpManager.connectServer(updated)
                        } else {
                            mcpManager.disconnectServer(server.id)
                        }
                    }
                ))

                Button(action: { mcpManager.reconnectServer(server) }) {
                    Image(systemName: "arrow.clockwise")
                        .font(HarborDesign.Font.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(action: {
                    configService.removeMCPServer(server.id)
                    mcpManager.disconnectServer(server.id)
                }) {
                    Image(systemName: "trash")
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
            }

            if state.isConnected {
                let tools = mcpManager.allTools.filter { $0.serverId == server.id }
                if !tools.isEmpty {
                    VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                        Text("Discovered Tools (\(tools.count))")
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)

                        ForEach(tools) { tool in
                            HStack(spacing: HarborDesign.Spacing.xs) {
                                Image(systemName: "wrench.and.screwdriver")
                                    .font(HarborDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                                Text(tool.name)
                                    .font(HarborDesign.Font.caption.monospaced())
                                Text("- \(tool.description)")
                                    .font(HarborDesign.Font.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Add MCP Server Form

    @ViewBuilder
    private var addMCPServerForm: some View {
        VStack(alignment: .leading, spacing: HarborDesign.Spacing.md) {
            TextField("Server Name", text: $newMCPServerName)
            TextField("Command (e.g., /usr/local/bin/mcp-server)", text: $newMCPServerCommand)
            TextField("Arguments (space-separated)", text: $newMCPServerArgs)

            HStack {
                Button("Cancel") {
                    showAddMCPServer = false
                    newMCPServerName = ""
                    newMCPServerCommand = ""
                    newMCPServerArgs = ""
                }
                Button("Add") {
                    let args = newMCPServerArgs.split(separator: " ").map(String.init)
                    let server = MCPServerConfig(
                        name: newMCPServerName,
                        transport: .stdio(command: newMCPServerCommand, args: args)
                    )
                    configService.addMCPServer(server)
                    mcpManager.connectServer(server)
                    showAddMCPServer = false
                    newMCPServerName = ""
                    newMCPServerCommand = ""
                    newMCPServerArgs = ""
                }
                .disabled(newMCPServerName.isEmpty || newMCPServerCommand.isEmpty)
            }
        }
    }

    // MARK: - Helpers

    private func testConnection(_ provider: AIProviderConfig) {
        testingConnection = true
        connectionTestResult = nil

        Task {
            do {
                switch provider.providerType {
                case .claudeACP, .codexACP:
                    break
                case .gemini:
                    // The key goes in a header; in the URL it would reach logs and proxies
                    var request = URLRequest(url: URL(string: "\(provider.baseURL)/models")!)
                    request.setValue(provider.apiKey, forHTTPHeaderField: "x-goog-api-key")
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        connectionTestResult = "Success: Connection verified"
                    } else {
                        connectionTestResult = "Failed: Invalid response"
                    }
                case .openRouter:
                    var request = URLRequest(url: URL(string: "\(provider.baseURL)/models")!)
                    request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        connectionTestResult = "Success: Connection verified"
                    } else {
                        connectionTestResult = "Failed: Invalid response"
                    }
                case .ollama:
                    let (_, response) = try await URLSession.shared.data(from: URL(string: "\(provider.baseURL)/api/tags")!)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        connectionTestResult = "Success: Ollama is running"
                    } else {
                        connectionTestResult = "Failed: Ollama not responding"
                    }
                case .openAICompatible:
                    var request = URLRequest(url: URL(string: "\(provider.baseURL)/models")!)
                    if !provider.apiKey.isEmpty {
                        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                        connectionTestResult = "Success: Connection verified"
                    } else {
                        connectionTestResult = "Failed: Invalid response"
                    }
                }
            } catch {
                connectionTestResult = "Failed: \(error.localizedDescription)"
            }
            testingConnection = false
        }
    }

    private func stateColor(_ state: MCPConnectionState) -> Color {
        switch state {
        case .connected: return .green
        case .connecting: return .orange
        case .disconnected: return .gray
        case .error: return .red
        }
    }
}
