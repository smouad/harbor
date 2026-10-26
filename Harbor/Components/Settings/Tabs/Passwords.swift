// Licensed under GPL-3.0. See LICENSE.
//
//  Passwords.swift
//  Harbor
//
//  Settings > Passwords: the logins Harbor fills in, where they came from, and a way to add
//  more from Arc, Dia or a file. Passwords stay in the keychain; a row shows none, and copying
//  one asks for the Mac's password or Touch ID first.
//

import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers
import HarborDesign

struct SettingsPasswordsTab: View {
    @EnvironmentObject var browserManager: BrowserManager
    @State private var logins: [SavedLogin] = []
    @State private var search = ""
    @State private var notice: String?
    @State private var isWorking = false

    private var shown: [SavedLogin] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !term.isEmpty else { return logins }
        return logins.filter { $0.host.contains(term) || $0.username.lowercased().contains(term) }
    }

    var body: some View {
        Form {
            Section {
                TextField("Search", text: $search)
                if shown.isEmpty {
                    Text(logins.isEmpty ? "No saved passwords" : "No matches")
                        .foregroundStyle(.secondary)
                }
                ForEach(shown) { login in
                    row(login)
                }
            } header: {
                Text("Saved Passwords")
            } footer: {
                Text("Harbor offers these when you click a sign-in field on the site they belong to. Passwords are kept in your keychain.")
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach([ChromiumBrowser.arc, ChromiumBrowser.dia].filter(\.isInstalled), id: \.name) { browser in
                    Button("Import from \(browser.name)…") { importFrom(browser) }
                }
                Button("Import from a File…", action: importFile)
                if !logins.isEmpty {
                    Button("Delete All…", role: .destructive, action: confirmDeleteAll)
                }
                if let notice {
                    Text(notice)
                        .font(HarborDesign.Font.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Import")
            }
            .disabled(isWorking)
        }
        .formStyle(.grouped)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: .savedLoginsChanged)) { _ in
            Task { await reload() }
        }
    }

    // MARK: - Rows

    private func row(_ login: SavedLogin) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: HarborDesign.Spacing.xxs) {
                Text(login.host).font(HarborDesign.Font.body)
                Text(login.username)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let spaceID = login.spaceID, let space = browserManager.tabs.space(spaceID) {
                Text(space.name)
                    .font(HarborDesign.Font.caption)
                    .foregroundStyle(.tertiary)
            }
            Menu {
                Button("Copy Username") { copy(login.username) }
                Button("Copy Password") { copyPassword(login) }
                Divider()
                Button("Delete", role: .destructive) { Task { await PasswordStore.shared.delete(login) } }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: HarborDesign.Size.iconButton, height: HarborDesign.Size.iconButton)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    private func reload() async {
        logins = await PasswordStore.shared.all()
    }

    // MARK: - Actions

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// A password leaves the keychain only after the person proves it is them.
    private func copyPassword(_ login: SavedLogin) {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Copy the saved password for \(login.host)") { allowed, _ in
            guard allowed else { return }
            Task { @MainActor in
                guard let password = await PasswordStore.shared.password(for: login) else { return NSSound.beep() }
                copy(password)
            }
        }
    }

    private func importFrom(_ browser: ChromiumBrowser) {
        isWorking = true
        notice = nil
        Task {
            let count = await browserManager.importSavedPasswords(from: browser)
            notice = count == 0 ? "No passwords were imported from \(browser.name)." : "Imported \(count) passwords from \(browser.name)."
            isWorking = false
        }
    }

    private func importFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        isWorking = true
        Task {
            let rows = LoginCSV.parse(text)
            let count = await PasswordStore.shared.save(rows.map { NewLogin(url: $0.url, username: $0.username, password: $0.password, spaceID: nil) })
            notice = count == 0 ? "No passwords were found in that file." : "Imported \(count) passwords."
            isWorking = false
        }
    }

    private func confirmDeleteAll() {
        let alert = NSAlert()
        alert.messageText = "Delete all saved passwords?"
        alert.informativeText = "This removes every password Harbor has saved. Passwords in other apps are not affected."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await PasswordStore.shared.deleteAll() }
    }
}
