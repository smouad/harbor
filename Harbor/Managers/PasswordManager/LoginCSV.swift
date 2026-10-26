// Licensed under GPL-3.0. See LICENSE.
//
//  LoginCSV.swift
//  Harbor
//
//  Reads the file a password export produces. Chrome, Arc, Dia, 1Password, Bitwarden and the
//  Passwords app each name their columns a little differently, so columns are found by header
//  name, not position. Pure: scripts/tests/LoginCSVCheck.swift compiles it on its own.
//

import Foundation

enum LoginCSV {
    struct Row: Equatable {
        let url: String
        let username: String
        let password: String
    }

    private static let urlHeaders = ["url", "login_uri", "website", "web site", "origin", "login url", "uri"]
    private static let userHeaders = ["username", "login_username", "user name", "user", "login", "email"]
    private static let passwordHeaders = ["password", "login_password", "pass"]

    static func parse(_ text: String) -> [Row] {
        let records = records(in: text)
        guard let header = records.first else { return [] }
        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        func column(_ candidates: [String]) -> Int? { candidates.compactMap { names.firstIndex(of: $0) }.first }
        guard let url = column(urlHeaders), let user = column(userHeaders), let password = column(passwordHeaders) else { return [] }
        return records.dropFirst().compactMap { fields in
            guard fields.indices.contains(url), fields.indices.contains(user), fields.indices.contains(password) else { return nil }
            let row = Row(url: fields[url], username: fields[user], password: fields[password])
            return row.url.isEmpty || row.password.isEmpty ? nil : row
        }
    }

    /// Splits CSV text into records of fields: quoted fields may hold commas, doubled quotes and
    /// line breaks.
    private static func records(in text: String) -> [[String]] {
        var records: [[String]] = []
        var fields: [String] = []
        var field = ""
        var quoted = false
        var iterator = text.makeIterator()
        var pending: Character? = iterator.next()
        func endField() { fields.append(field); field = "" }
        func endRecord() {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) { records.append(fields) }
            fields = []
        }
        while let character = pending {
            pending = iterator.next()
            if quoted {
                if character == "\"" {
                    if pending == "\"" { field.append("\""); pending = iterator.next() } else { quoted = false }
                } else {
                    field.append(character)
                }
                continue
            }
            switch character {
            case "\"": quoted = true
            case ",": endField()
            // Swift reads "\r\n" as one character, so a Windows file needs no special case.
            case "\n", "\r\n", "\r": endRecord()
            default: field.append(character)
            }
        }
        if !field.isEmpty || !fields.isEmpty { endRecord() }
        return records
    }
}
