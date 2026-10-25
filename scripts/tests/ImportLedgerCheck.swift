// Checks that ImportLedger keeps what an import added across a restart, and forgets it on reset.
//
//   scripts/tests/run-ledger-check.sh   (compiles ImportLedger out of BrowserManager+Import.swift)
import Foundation

@main
struct Check {
    @MainActor static func main() {
        let suite = "ledger-check-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        func expect(_ ok: Bool, _ what: String) { if !ok { print("FAIL: \(what)"); exit(1) } }

        let space = UUID(), item = UUID()
        let first = ImportLedger(defaults: defaults)
        expect(first.begin("arc").spaces.isEmpty, "first import has nothing before it")
        first.add(space: space); first.add(item: item); first.end()

        let relaunched = ImportLedger(defaults: defaults)  // a new process reads the same defaults
        let previous = relaunched.begin("arc")
        expect(previous.spaces == [space] && previous.items == [item], "restart still knows the first import")
        expect(relaunched.begin("dia").spaces.isEmpty, "another browser starts empty")
        relaunched.end()

        relaunched.reset()
        expect(ImportLedger(defaults: defaults).begin("arc").spaces.isEmpty, "setup finished: nothing to replace")
        print("ok")
    }
}
