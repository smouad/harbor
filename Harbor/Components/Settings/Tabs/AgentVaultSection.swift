// Licensed under GPL-3.0. See LICENSE.
//
//  AgentVaultSection.swift
//  Harbor
//
//  Settings > Developer: secrets the person lends an agent without telling it. The agent types
//  {{secret:name}}; Harbor fills the value in, only on the sites listed for it (AgentVault).
//

import SwiftUI
import HarborDesign

struct AgentVaultSection: View {
    @State private var name = ""
    @State private var sites = ""
    @State private var value = ""
    @State private var error: String?
    private let vault = AgentHub.shared.vault

    var body: some View {
        Section {
            ForEach(vault.entries) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                        Text(entry.name)
                            .font(HarborDesign.Font.body)
                        Text(entry.domains.isEmpty ? "No sites" : entry.domains.joined(separator: ", "))
                            .font(HarborDesign.Font.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove", role: .destructive) { Task { await vault.remove(entry.name) } }
                }
            }
            TextField("Name", text: $name, prompt: Text("work_email_password"))
            TextField("Sites", text: $sites, prompt: Text("example.com, login.example.com"))
            SecureField("Value", text: $value)
            HStack {
                if let error {
                    Text(error)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(HarborDesign.Surface.danger)
                }
                Spacer()
                Button("Add Secret", action: add)
                    .disabled(name.isEmpty || value.isEmpty || sites.isEmpty)
            }
        } header: {
            Text("Agent Vault")
        } footer: {
            Text("An agent types {{secret:name}} and Harbor fills in the value, only on the sites you list. Agent tools never return it, and scripts cannot run on the page it was typed into unless you approve them. Values are kept in your keychain.")
                .font(HarborDesign.Font.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        Task {
            do {
                try await vault.save(name: name, domains: sites.split(separator: ",").map(String.init), value: value)
                name = ""
                sites = ""
                value = ""
                error = nil
            } catch {
                self.error = error.agentMessage
            }
        }
    }
}
