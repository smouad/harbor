// Licensed under GPL-3.0. See LICENSE.
//
//  PasswordStore.swift
//  Harbor
//
//  The logins Harbor fills in: one generic keychain item per login, the password as its secret
//  and everything else (site, user name, space, date) as attributes. Listing a site's logins reads
//  attributes only, so a password is read once, when the person picks that login.
//
//  Items are created by this app and its keychain access list names it alone, so another app's
//  request for them makes macOS ask. A login belongs to one space (the profile it came from, which
//  is one login context) or to every space.
//

import Foundation
import Security

extension Notification.Name {
    /// Posted after logins were added, changed or removed, so open lists can reload.
    static let savedLoginsChanged = Notification.Name("HarborSavedLoginsChanged")
}

/// One saved login, without its password.
struct SavedLogin: Identifiable, Hashable, Codable, Sendable {
    /// The keychain account: space, host and user name, so the same login saved twice is one item.
    let id: String
    let host: String
    /// The page the login was saved on, as the browser it came from recorded it.
    let origin: String
    let username: String
    /// Nil: offered in every space.
    let spaceID: UUID?
    let created: Date

    static func accountKey(space: UUID?, host: String, username: String) -> String {
        [space?.uuidString ?? "all", host.lowercased(), username].joined(separator: "\u{1F}")
    }
}

/// A login on its way in.
struct NewLogin {
    let url: String
    let username: String
    let password: String
    var spaceID: UUID?
}

actor PasswordStore {
    static let shared = PasswordStore()

    private let service: String
    private var cache: [SavedLogin]?

    /// For checks that open a second store on the same keychain service.
    var serviceName: String { service }

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.mouad.harbor") + ".logins") {
        self.service = service
    }

    // MARK: - Reading

    /// Every login, newest first.
    func all() -> [SavedLogin] {
        if let cache { return cache }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            cache = []
            return []
        }
        let decoder = JSONDecoder()
        let logins = items.compactMap { item -> SavedLogin? in
            guard let data = item[kSecAttrGeneric as String] as? Data else { return nil }
            return try? decoder.decode(SavedLogin.self, from: data)
        }.sorted { $0.created > $1.created }
        cache = logins
        return logins
    }

    /// The logins offered on a page: this site's, from this space or from every space, the page's
    /// exact host first. A private window passes no space, so it sees only the shared ones.
    func logins(forHost host: String, space: UUID?) -> [SavedLogin] {
        all()
            .filter { LoginMatching.matches(loginHost: $0.host, pageHost: host) && ($0.spaceID == nil || $0.spaceID == space) }
            .sorted { lhs, rhs in
                let (a, b) = (LoginMatching.isExact(loginHost: lhs.host, pageHost: host), LoginMatching.isExact(loginHost: rhs.host, pageHost: host))
                return a == b ? lhs.created > rhs.created : a
            }
    }

    func hasLogins(forHost host: String, space: UUID?) -> Bool {
        !logins(forHost: host, space: space).isEmpty
    }

    /// The password for one login. Never prompts: if macOS would have to ask, this returns nil.
    func password(for login: SavedLogin) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: login.id, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Writing

    /// Adds logins, replacing one already saved for the same space, host and user name. Entries
    /// with no usable host or an empty user name or password are skipped. Returns how many were
    /// written.
    @discardableResult
    func save(_ logins: [NewLogin]) -> Int {
        var written = 0
        let encoder = JSONEncoder()
        for login in logins {
            guard let host = Self.host(of: login.url), !login.password.isEmpty else { continue }
            let key = SavedLogin.accountKey(space: login.spaceID, host: host, username: login.username)
            let record = SavedLogin(id: key, host: host, origin: login.url, username: login.username,
                                    spaceID: login.spaceID, created: Date())
            guard let meta = try? encoder.encode(record), let secret = login.password.data(using: .utf8) else { continue }
            let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                           kSecAttrService as String: service, kSecAttrAccount as String: key]
            var status = SecItemUpdate(identity as CFDictionary,
                                       [kSecValueData as String: secret, kSecAttrGeneric as String: meta] as CFDictionary)
            if status == errSecItemNotFound {
                var add = identity
                add[kSecValueData as String] = secret
                add[kSecAttrGeneric as String] = meta
                add[kSecAttrLabel as String] = "Harbor login: \(host)"
                add[kSecAttrDescription as String] = login.username
                status = SecItemAdd(add as CFDictionary, nil)
            }
            if status == errSecSuccess { written += 1 }
        }
        cache = nil
        notifyChanged()
        return written
    }

    func delete(_ login: SavedLogin) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: login.id]
        SecItemDelete(query as CFDictionary)
        cache = nil
        notifyChanged()
    }

    func deleteAll() {
        // On macOS SecItemDelete removes a single match unless it is told to take them all.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecMatchLimit as String: kSecMatchLimitAll]
        SecItemDelete(query as CFDictionary)
        cache = nil
        notifyChanged()
    }

    // MARK: - Helpers

    private func notifyChanged() {
        Task { @MainActor in NotificationCenter.default.post(name: .savedLoginsChanged, object: nil) }
    }

    /// The host a saved page URL stands for. A bare host ("example.com") counts too.
    static func host(of url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if let host = URL(string: trimmed)?.host?.lowercased(), !host.isEmpty { return host }
        if let host = URL(string: "https://" + trimmed)?.host?.lowercased(), host.contains(".") { return host }
        return nil
    }
}
