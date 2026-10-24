// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPolicy.swift
//  Harbor
//
//  The agent's rules that need no browser: which sites a task may open, how secret placeholders
//  are found and kept out of logs, and which actions count as sensitive. Foundation only, so
//  scripts/tests/AgentPolicyCheck.swift compiles it directly.
//

import Foundation

// MARK: - Scope

/// Which sites a task may open. Entries are hosts ("shop.example.com"), a leading-dot or `*.`
/// domain ("*.example.com" covers it and its subdomains), or full origins ("https://example.com").
/// A bare host also covers its subdomains, the way people write it.
enum AgentScope {
    static func allows(_ url: URL, origins: [String]) -> Bool {
        guard !origins.isEmpty else { return true }
        guard let scheme = url.scheme?.lowercased() else { return false }
        // Pages that are not a site carry no new origin.
        if ["about", "data", "blob"].contains(scheme) { return true }
        guard let host = url.host?.lowercased() else { return false }
        return origins.contains { matches(host: host, scheme: scheme, port: url.port, entry: $0) }
    }

    static func matches(host: String, scheme: String, port: Int?, entry raw: String) -> Bool {
        var entry = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !entry.isEmpty else { return false }
        if entry.contains("://") {
            guard let url = URL(string: entry), let entryHost = url.host?.lowercased() else { return false }
            return url.scheme?.lowercased() == scheme && entryHost == host && url.port == port
        }
        if entry.hasPrefix("*.") { entry.removeFirst(2) } else if entry.hasPrefix(".") { entry.removeFirst() }
        if let slash = entry.firstIndex(of: "/") { entry = String(entry[..<slash]) }
        if let colon = entry.firstIndex(of: ":") { entry = String(entry[..<colon]) }
        return host == entry || host.hasSuffix("." + entry)
    }
}

// MARK: - Secret placeholders

/// `{{secret:name}}` in text an agent types stands for a vault secret the agent never sees.
enum AgentPlaceholders {
    private static let pattern = try! NSRegularExpression(pattern: #"\{\{\s*secret\s*:\s*([A-Za-z0-9_.-]+)\s*\}\}"#)

    static func names(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// `text` with each placeholder replaced by `lookup(name)`; nil when any name has no value.
    static func fill(_ text: String, lookup: (String) -> String?) -> String? {
        var out = ""
        var cursor = text.startIndex
        let range = NSRange(text.startIndex..., in: text)
        for match in pattern.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text),
                  let value = lookup(String(text[nameRange])) else { return nil }
            out += text[cursor..<whole.lowerBound]
            out += value
            cursor = whole.upperBound
        }
        return out + text[cursor...]
    }
}

// MARK: - Sensitive actions

/// What an action does, from metadata only (never the page's text around it), for the critic.
struct AgentActionFacts {
    var action: String
    /// The element's accessible role and name, as the runtime describes it.
    var role: String = ""
    var name: String = ""
    var inputType: String = ""
    var host: String = ""
    var url: String = ""
    var key: String = ""
    var typedSecret = false
}

enum AgentSensitivity {
    /// Why an action needs the person's approval under the `sensitive` policy, or nil.
    static func reason(for facts: AgentActionFacts) -> String? {
        let name = facts.name.lowercased()
        let action = facts.action
        // A script can do anything a click can, and read what was typed: one approval covers
        // the task's scripts for a while (the grant is per task, not per script).
        if action == "eval" { return "Runs a script on \(facts.host.isEmpty ? "the page" : facts.host)" }
        if ["click", "submit", "check", "press"].contains(action) {
            for (words, why) in rules where words.contains(where: { matchesWord($0, in: name) }) {
                return why
            }
        }
        if action == "submit" { return "Submits a form" }
        if action == "press", facts.key.lowercased() == "enter", facts.inputType == "password" { return "Signs in" }
        if ["fill", "type", "setValue"].contains(action) {
            if facts.inputType == "password", !facts.typedSecret { return "Types a password the person did not store in the vault" }
            if payment.contains(where: { matchesWord($0, in: name) }) { return "Enters payment details" }
        }
        if action == "upload" { return "Uploads a file to \(facts.host.isEmpty ? "the site" : facts.host)" }
        return nil
    }

    private static let payment = ["card number", "credit card", "cvv", "cvc", "security code", "iban", "expiry", "expiration"]

    private static let rules: [([String], String)] = [
        (["buy", "purchase", "place order", "pay", "checkout", "check out", "confirm order", "complete order",
          "subscribe", "upgrade", "donate", "book now", "reserve"], "Spends money"),
        (["send", "post", "publish", "tweet", "reply", "comment", "share", "submit"], "Sends or publishes something"),
        (["delete", "remove", "erase", "discard", "deactivate", "close account", "cancel subscription", "unsubscribe"],
         "Deletes something"),
        (["transfer", "withdraw", "wire"], "Moves money"),
        (["sign in", "log in", "login", "sign up", "register", "authorize", "allow access", "grant"], "Signs in or grants access"),
        (["change password", "reset password", "change email", "two-factor", "2fa"], "Changes account security")
    ]

    /// Whole-word match, so "repost" is not "post" and "display" is not "pay".
    static func matchesWord(_ phrase: String, in text: String) -> Bool {
        guard let range = text.range(of: phrase) else { return false }
        let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
        let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
        let isWordChar: (Character?) -> Bool = { $0.map { $0.isLetter || $0.isNumber } ?? false }
        if !isWordChar(before) && !isWordChar(after) { return true }
        // Try later occurrences too.
        let rest = String(text[range.upperBound...])
        return matchesWord(phrase, in: rest)
    }
}

// MARK: - Templates

/// `${vars.name}`, `${input.x.y}` in recipe and act steps, read from named scopes. A string that is
/// one placeholder and nothing else keeps the value's own type (a list stays a list); inside
/// other text the value is written as text. An unknown name is left as written.
enum AgentTemplate {
    private static let pattern = try! NSRegularExpression(pattern: #"\$\{\s*([A-Za-z_][\w]*(?:\.[\w]+)*)\s*\}"#)

    static func fill(_ value: Any, scopes: [String: Any]) -> Any {
        switch value {
        case let text as String: return fillString(text, scopes: scopes)
        case let list as [Any]: return list.map { fill($0, scopes: scopes) }
        case let dict as [String: Any]: return dict.mapValues { fill($0, scopes: scopes) }
        default: return value
        }
    }

    static func lookup(_ path: String, in scopes: [String: Any]) -> Any? {
        var current: Any? = scopes
        for part in path.split(separator: ".") {
            if let dict = current as? [String: Any] { current = dict[String(part)] }
            else if let list = current as? [Any], let index = Int(part), list.indices.contains(index) { current = list[index] }
            else { return nil }
        }
        return current
    }

    private static func fillString(_ text: String, scopes: [String: Any]) -> Any {
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern.matches(in: text, range: range)
        guard !matches.isEmpty else { return text }
        if matches.count == 1, matches[0].range == range,
           let path = Range(matches[0].range(at: 1), in: text), let value = lookup(String(text[path]), in: scopes) {
            return value
        }
        var out = ""
        var cursor = text.startIndex
        for match in matches {
            guard let whole = Range(match.range, in: text), let path = Range(match.range(at: 1), in: text) else { continue }
            out += text[cursor..<whole.lowerBound]
            if let value = lookup(String(text[path]), in: scopes) { out += describe(value) } else { out += text[whole] }
            cursor = whole.upperBound
        }
        return out + text[cursor...]
    }

    private static func describe(_ value: Any) -> String {
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default:
            guard JSONSerialization.isValidJSONObject(value),
                  let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "\(value)" }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
