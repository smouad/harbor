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
    /// Values typed this session, by name, kept in memory only so `scrub` can find them.
    @ObservationIgnored private var typed: [String: String] = [:]

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
            let value = try await Self.readOffMain(name)
            values[name] = value
            typed[name] = value
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

    /// `text` with every value typed this session put back as its placeholder, raw or in the
    /// encodings a page passes it on in (a form's URL, a request body, JSON). The last line of
    /// defence: a page can echo what was typed into it anywhere.
    func scrub(_ text: String) -> String {
        typed.isEmpty ? text : AgentPlaceholders.scrub(text, values: typed)
    }

    /// The same text as MCP content items, scrubbed.
    func scrub(content: [[String: Any]]) -> [[String: Any]] {
        guard !typed.isEmpty else { return content }
        return content.map { item in
            guard let text = item["text"] as? String else { return item }
            var item = item
            item["text"] = scrub(text)
            return item
        }
    }

    // MARK: - For the person (Settings)

    /// Off the main thread: a Keychain write may wait on an access prompt.
    func save(name: String, domains: [String], value: String) async throws {
        guard name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw VaultError.badName }
        try await Task.detached(priority: .userInitiated) { try Self.write(name, value: value) }.value
        let cleaned = domains.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let index = entries.firstIndex(where: { $0.name == name }) {
            entries[index].domains = cleaned
        } else {
            entries.append(Entry(name: name, domains: cleaned))
        }
        persist()
    }

    func remove(_ name: String) async {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: Self.service, kSecAttrAccount as String: name]
        _ = await Task.detached(priority: .userInitiated) { SecItemDelete(query as CFDictionary) }.value
        entries.removeAll { $0.name == name }
        typed.removeValue(forKey: name)
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

    nonisolated private static func write(_ name: String, value: String) throws {
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
