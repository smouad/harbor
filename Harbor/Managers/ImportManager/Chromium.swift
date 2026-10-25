// Licensed under GPL-3.0. See LICENSE.
//
//  Chromium.swift
//  Harbor
//
//  Reads what a Chromium-based browser keeps in a profile folder: cookies (the accounts it is
//  signed in to), saved passwords, history and bookmarks. Arc and Dia both are. Cookies and
//  passwords are encrypted with a key the browser keeps in the login keychain as
//  "<Name> Safe Storage"; reading it makes macOS ask the person once. Everything is read from
//  copies of the databases, since the browser may be running, and nothing leaves this Mac.
//

import CommonCrypto
import Foundation
import Security
import SQLite3

// MARK: - Browsers

struct ChromiumBrowser {
    let name: String
    /// `~/Library/Application Support/<Name>/User Data`, which holds one folder per profile.
    let userData: URL
    /// The keychain item holding the key that encrypts cookies and passwords.
    let keychainService: String
    let keychainAccount: String

    private static func support(_ folder: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(folder)/User Data")
    }

    static let arc = ChromiumBrowser(name: "Arc", userData: support("Arc"),
                                     keychainService: "Arc Safe Storage", keychainAccount: "Arc")
    static let dia = ChromiumBrowser(name: "Dia", userData: support("Dia"),
                                     keychainService: "Dia Safe Storage", keychainAccount: "Dia")

    var isInstalled: Bool { FileManager.default.fileExists(atPath: userData.path) }
}

/// What the person chose to bring over besides tabs and spaces. Signed-in accounts and passwords
/// start off: both are secrets, so they are brought over only when asked for.
struct ChromiumImportOptions: Equatable {
    var signIns = false
    var history = true
    var bookmarks = true
    var passwords = false

    /// Sign-ins and passwords are encrypted with a key in the keychain, which macOS asks about.
    /// Without either, the keychain is never touched.
    var needsKey: Bool { signIns || passwords }
}

struct ChromiumProfile {
    /// The folder name under User Data: "Default", "Profile 1".
    let directory: String
    /// The name the person gave it.
    let name: String
}

struct ChromiumLogin {
    let url: String
    let username: String
    let password: String
}

struct ChromiumVisit {
    let url: String
    let title: String
    let date: Date
}

indirect enum ChromiumBookmark {
    case page(title: String, url: String)
    case folder(title: String, items: [ChromiumBookmark])
}

// MARK: - Reader

struct ChromiumReader {
    let browser: ChromiumBrowser

    /// The profiles Chromium lists in `Local State`, in folder-name order, else every profile folder.
    func profiles() -> [ChromiumProfile] {
        let localState = browser.userData.appendingPathComponent("Local State")
        var named: [String: String] = [:]
        if let data = try? Data(contentsOf: localState),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = (root["profile"] as? [String: Any])?["info_cache"] as? [String: Any] {
            for (directory, info) in cache {
                named[directory] = (info as? [String: Any])?["name"] as? String
            }
        }
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: browser.userData.path)) ?? []
        let directories = folders.filter { $0 == "Default" || $0.hasPrefix("Profile ") }
        return directories.sorted { Self.profileOrder($0) < Self.profileOrder($1) }
            .map { ChromiumProfile(directory: $0, name: named[$0] ?? $0) }
    }

    private static func profileOrder(_ directory: String) -> Int {
        directory == "Default" ? 0 : (Int(directory.dropFirst("Profile ".count)) ?? Int.max)
    }

    // MARK: Key

    /// The AES key Chromium derives from the keychain item, or nil when the person says no or
    /// the item is not there. Blocks while macOS asks, so call it off the main thread.
    func encryptionKey() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: browser.keychainService,
            kSecAttrAccount as String: browser.keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let password = item as? Data else { return nil }
        return Self.deriveKey(password: password)
    }

    /// PBKDF2-HMAC-SHA1 with Chromium's fixed salt and 1003 rounds, to a 128-bit key.
    static func deriveKey(password: Data) -> Data? {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { raw -> Int32 in
            let bytes = raw.bindMemory(to: Int8.self)
            return CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress, password.count, salt, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        return status == Int32(kCCSuccess) ? Data(key) : nil
    }

    /// Chromium's "v10" value: AES-128-CBC with sixteen spaces as the IV.
    static func decrypt(_ blob: Data, key: Data) -> Data? {
        guard blob.count > 3, blob.prefix(3) == Data("v10".utf8) || blob.prefix(3) == Data("v11".utf8) else { return nil }
        let cipher = blob.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        var moved = 0
        let status = cipher.withUnsafeBytes { input in
            key.withUnsafeBytes { keyBytes in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, input.baseAddress, cipher.count, &out, out.count, &moved)
            }
        }
        return status == Int32(kCCSuccess) ? Data(out.prefix(moved)) : nil
    }

    // MARK: Cookies

    /// A profile's cookies as WebKit cookies. A cookie that cannot be decrypted is skipped.
    func cookies(in profile: ChromiumProfile, key: Data) -> [HTTPCookie] {
        let file = browser.userData.appendingPathComponent("\(profile.directory)/Cookies")
        let network = browser.userData.appendingPathComponent("\(profile.directory)/Network/Cookies")
        let database = FileManager.default.fileExists(atPath: network.path) ? network : file
        // From database version 24 the plain value starts with a SHA-256 of the cookie's host.
        var version = 0
        Self.query(database, "SELECT value FROM meta WHERE key = 'version'") { row in
            version = Int(Self.text(row, 0)) ?? 0
        }
        var cookies: [HTTPCookie] = []
        Self.query(database, """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly,
                   samesite, has_expires FROM cookies
            """) { row in
            let host = Self.text(row, 0), name = Self.text(row, 1)
            var value = Self.text(row, 2)
            let encrypted = Self.blob(row, 3)
            if value.isEmpty, !encrypted.isEmpty {
                guard var plain = Self.decrypt(encrypted, key: key) else { return }
                if version >= 24 { plain = plain.dropFirst(32) }
                guard let text = String(data: plain, encoding: .utf8) else { return }
                value = text
            }
            var properties: [HTTPCookiePropertyKey: Any] = [
                .domain: host, .name: name, .value: value,
                .path: Self.text(row, 4).isEmpty ? "/" : Self.text(row, 4),
            ]
            let expires = sqlite3_column_int64(row, 5)
            if sqlite3_column_int(row, 9) != 0, expires > 0 {
                let date = Date(timeIntervalSince1970: Double(expires) / 1_000_000 - 11_644_473_600)
                guard date > Date() else { return }
                properties[.expires] = date
            }
            if sqlite3_column_int(row, 6) != 0 { properties[.secure] = "TRUE" }
            if sqlite3_column_int(row, 7) != 0 { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            switch sqlite3_column_int(row, 8) {
            case 1: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax
            case 2: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict
            default: break
            }
            if let cookie = HTTPCookie(properties: properties) { cookies.append(cookie) }
        }
        return cookies
    }

    // MARK: Passwords

    /// Saved logins from the profile's own store and its account store. Sites the person told the
    /// browser never to save for, and entries that cannot be decrypted, are left out.
    func logins(in profile: ChromiumProfile, key: Data) -> [ChromiumLogin] {
        var logins: [ChromiumLogin] = []
        for name in ["Login Data", "Login Data For Account"] {
            let database = browser.userData.appendingPathComponent("\(profile.directory)/\(name)")
            Self.query(database, """
                SELECT origin_url, username_value, password_value FROM logins
                WHERE blacklisted_by_user = 0 AND length(password_value) > 0
                """) { row in
                guard let plain = Self.decrypt(Self.blob(row, 2), key: key),
                      let password = String(data: plain, encoding: .utf8), !password.isEmpty else { return }
                logins.append(ChromiumLogin(url: Self.text(row, 0), username: Self.text(row, 1), password: password))
            }
        }
        return logins
    }

    // MARK: History

    /// The most recent web visits, newest first.
    func history(in profile: ChromiumProfile, limit: Int = 20_000) -> [ChromiumVisit] {
        let database = browser.userData.appendingPathComponent("\(profile.directory)/History")
        var visits: [ChromiumVisit] = []
        Self.query(database, """
            SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url
            ORDER BY v.visit_time DESC LIMIT \(limit)
            """) { row in
            let url = Self.text(row, 0)
            guard url.hasPrefix("http://") || url.hasPrefix("https://") else { return }
            let seconds = Double(sqlite3_column_int64(row, 2)) / 1_000_000 - 11_644_473_600
            visits.append(ChromiumVisit(url: url, title: Self.text(row, 1), date: Date(timeIntervalSince1970: seconds)))
        }
        return visits
    }

    // MARK: Bookmarks

    /// The bookmarks bar, "Other bookmarks" and mobile bookmarks, each as a folder.
    func bookmarks(in profile: ChromiumProfile) -> [ChromiumBookmark] {
        let file = browser.userData.appendingPathComponent("\(profile.directory)/Bookmarks")
        guard let data = try? Data(contentsOf: file),
              let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["roots"] as? [String: Any]
        else { return [] }
        func node(_ value: Any?) -> ChromiumBookmark? {
            guard let item = value as? [String: Any] else { return nil }
            let title = (item["name"] as? String) ?? ""
            if (item["type"] as? String) == "url" {
                guard let url = item["url"] as? String, url.hasPrefix("http") else { return nil }
                return .page(title: title.isEmpty ? url : title, url: url)
            }
            let children = (item["children"] as? [Any] ?? []).compactMap(node)
            return children.isEmpty ? nil : .folder(title: title, items: children)
        }
        return ["bookmark_bar", "other", "synced"].compactMap { node(root[$0]) }
    }

    // MARK: SQLite

    /// Runs `sql` against a copy of `database` (and its write-ahead log), calling `row` for each row.
    private static func query(_ database: URL, _ sql: String, row: (OpaquePointer) -> Void) {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: database.path) else { return }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("harbor-import-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: folder) }
        guard (try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])) != nil else { return }
        let copy = folder.appendingPathComponent("db")
        guard (try? fileManager.copyItem(at: database, to: copy)) != nil else { return }
        for suffix in ["-wal", "-shm"] {
            let extra = URL(fileURLWithPath: database.path + suffix)
            if fileManager.fileExists(atPath: extra.path) {
                try? fileManager.copyItem(at: extra, to: URL(fileURLWithPath: copy.path + suffix))
            }
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else { return }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func text(_ row: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(row, column).map { String(cString: $0) } ?? ""
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let bytes = sqlite3_column_blob(row, column) else { return Data() }
        return Data(bytes: bytes, count: count)
    }
}

// MARK: - Password export

enum PasswordCSV {
    /// The format Chrome exports and Passwords, 1Password and Bitwarden import: name, url,
    /// username, password, note.
    static func make(_ logins: [ChromiumLogin]) -> String {
        func field(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["name,url,username,password,note"]
        for login in logins {
            let host = URL(string: login.url)?.host ?? login.url
            lines.append([host, login.url, login.username, login.password, ""].map(field).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
