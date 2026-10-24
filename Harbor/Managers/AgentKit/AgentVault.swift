// Licensed under GPL-3.0. See LICENSE.
//
//  AgentVault.swift
//  Harbor
//
//  Secrets the person lends the agent without telling it: the agent types `{{secret:name}}` and
//  Harbor puts the value into the page, only on the sites the person allowed for that secret. The
//  value never appears in a tool's result, a replay or a log. Values live in the Keychain
//  (service `<bundle id>.agent-vault`); vault.json holds only names and sites.
//

import Foundation
import Observation
import Security

@MainActor
@Observable
final class AgentVault {
    struct Entry: Codable, Identifiable, Equatable {
        var name: String
        var domains: [String]
        var id: String { name }
    }

    enum VaultError: LocalizedError {
        case unknown(String)
        case wrongSite(String, String)
        case keychain(OSStatus)
        case keychainBusy
        case needsPermission(String)
        case badName

        var errorDescription: String? {
            switch self {
            case .unknown(let name): "No secret named \(name). The person adds secrets in Settings > Developer."
            case .wrongSite(let name, let host): "Secret \(name) is not allowed on \(host)"
            case .keychain(let status): "Keychain error \(status)"
            case .keychainBusy: "The keychain did not answer"
            case .needsPermission(let name): "Harbor may not read secret \(name) without asking. The person can save it again in Settings > Developer."
            case .badName: "A secret's name is letters, digits, dot, dash or underscore"
            }
        }
    }

    private(set) var entries: [Entry] = []

    nonisolated private static let service = (Bundle.main.bundleIdentifier ?? "Harbor") + ".agent-vault"
    private static var file: URL { AgentHub.directory.appendingPathComponent("vault.json") }

    init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    // MARK: - For the agent

    /// `text` with its placeholders filled for a page on `host`. Throws when a secret is unknown or
    /// not allowed there, so nothing is typed.
    func fill(_ text: String, host: String) async throws -> String {
        var values: [String: String] = [:]
        for name in Set(AgentPlaceholders.names(in: text)) {
            guard let entry = entries.first(where: { $0.name == name }) else { throw VaultError.unknown(name) }
            guard entry.domains.contains(where: { AgentScope.matches(host: host.lowercased(), scheme: "https", port: nil, entry: $0) }) else {
                throw VaultError.wrongSite(name, host)
            }
            values[name] = try await Self.readOffMain(name)
        }
        guard let filled = AgentPlaceholders.fill(text, lookup: { values[$0] }) else {
            throw VaultError.unknown(AgentPlaceholders.names(in: text).first ?? "")
        }
        return filled
    }

    /// A Keychain read can wait on the person (an unlock or access prompt), so it never runs on
    /// the main thread: one did, and the whole app froze behind the prompt.
    private static func readOffMain(_ name: String) async throws -> String {
        do {
            return try await AgentDeadline.throwing(Self.keychainTimeout) {
                try await Task.detached(priority: .userInitiated) { try read(name) }.value
            }
        } catch is AgentDeadline.Expired {
            throw VaultError.keychainBusy
        }
    }

    private static let keychainTimeout: Double = 15

    // MARK: - For the person (Settings)

    func save(name: String, domains: [String], value: String) throws {
        guard name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw VaultError.badName }
        try Self.write(name, value: value)
        let cleaned = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index].domains = cleaned
        } else {
            entries.append(Entry(name: name, domains: cleaned))
        }
        persist()
    }

    func remove(_ name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service, kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
        entries.removeAll { $0.name == name }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }

    // MARK: - Keychain

    nonisolated private static func read(_ name: String) throws -> String {
        // Never a prompt: nobody may be watching an agent, and an unanswered one held the read.
        // An item Harbor saved itself reads without one; anything else fails here instead.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name, kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw VaultError.unknown(name) }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed {
            throw VaultError.needsPermission(name)
        }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw VaultError.keychain(status)
        }
        return value
    }

    private static func write(_ name: String, value: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        let data = Data(value.utf8)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Harbor agent secret: \(name)"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }
}
