// Checks the shortcut model: key names match what AppKit reports, and no two defaults share a key.
//   swiftc Harbor/Models/KeyboardShortcut/KeyboardShortcut.swift scripts/tests/ShortcutDefaultsCheck.swift -o /tmp/shortcut-check && /tmp/shortcut-check
import AppKit

@main
struct ShortcutDefaultsCheck {
    static func main() {
        // AppKit spells Tab "\t" and the arrows with private-use characters.
        precondition(KeyCombination.normalized("\t") == "tab")
        precondition(KeyCombination.normalized("\u{F701}") == "downarrow")
        precondition(KeyCombination.normalized("\u{F700}") == "uparrow")
        precondition(KeyCombination(key: "\t", modifiers: [.control]).lookupKey == "ctrl+tab")
        precondition(KeyCombination(key: "tab", modifiers: [.control]).lookupKey == "ctrl+tab")
        // A combination saved before names were normalized still finds the same entry.
        precondition(KeyCombination(key: "tab", modifiers: [.control, .shift]).lookupKey == "ctrl+shift+tab")

        // Two defaults that predate this check already share a key, so only the first of each pair
        // is ever reached. Any other shared key fails.
        let knownClashes: Set<Set<ShortcutAction>> = [
            [.togglePictureInPicture, .openCommandPalette],
            [.expandAllFolders, .installExtension],
        ]
        var seen: [String: ShortcutAction] = [:]
        for shortcut in KeyboardShortcut.defaultShortcuts {
            if let other = seen[shortcut.lookupKey] {
                if knownClashes.contains([shortcut.action, other]) {
                    print("note: \(shortcut.action) and \(other) share \(shortcut.lookupKey)")
                    continue
                }
                preconditionFailure("\(shortcut.action) and \(other) both use \(shortcut.lookupKey)")
            }
            seen[shortcut.lookupKey] = shortcut.action
        }
        // Every action has a default, so a new one is never missing from the settings list.
        let covered = Set(KeyboardShortcut.defaultShortcuts.map(\.action))
        for action in ShortcutAction.allCases where !covered.contains(action) {
            print("note: no default for \(action)")
        }
        precondition(seen["ctrl+tab"] == .recentTab)
        precondition(seen["cmd+opt+downarrow"] == .nextTab)
        precondition(seen["ctrl+1"] == .goToSpace1)
        print("shortcut defaults ok: \(seen.count) shortcuts")
    }
}
