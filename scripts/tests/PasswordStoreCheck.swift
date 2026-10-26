// swiftc -parse-as-library Harbor/Managers/PasswordManager/PasswordStore.swift Harbor/Managers/PasswordManager/LoginMatching.swift scripts/tests/PasswordStoreCheck.swift -o /tmp/psc && /tmp/psc
// Uses its own keychain service, and removes what it adds.
import Foundation

@main
struct PasswordStoreCheck {
    static func main() async {
        let store = PasswordStore(service: "com.mouad.harbor.logintest.\(UUID().uuidString)")
        await store.deleteAll()
        let work = UUID(), personal = UUID()

        let written = await store.save([
            NewLogin(url: "https://www.example.com/login", username: "me@work.com", password: "work-pw", spaceID: work),
            NewLogin(url: "https://example.com", username: "me@home.com", password: "home-pw", spaceID: personal),
            NewLogin(url: "https://example.com/a", username: "shared", password: "shared-pw", spaceID: nil),
            NewLogin(url: "https://other.org", username: "x", password: "y", spaceID: nil),
            NewLogin(url: "not a url", username: "bad", password: "bad", spaceID: nil),
            NewLogin(url: "https://empty.com", username: "nopw", password: "", spaceID: nil),
        ])
        precondition(written == 4, "bad URL and empty password are skipped, got \(written)")

        // A space sees its own logins and the shared ones, on any host of the same site.
        let inWork = await store.logins(forHost: "login.example.com", space: work)
        precondition(Set(inWork.map(\.username)) == ["me@work.com", "shared"], "got \(inWork.map(\.username))")
        let inPersonal = await store.logins(forHost: "example.com", space: personal)
        precondition(Set(inPersonal.map(\.username)) == ["me@home.com", "shared"], "got \(inPersonal.map(\.username))")
        // The page's own host leads: on example.com the login saved for example.com comes before
        // the one saved for www.example.com, though that one is newer.
        let onBare = await store.logins(forHost: "example.com", space: work)
        precondition(onBare.first?.host == "example.com" && onBare.last?.host == "www.example.com", "exact host first, got \(onBare.map(\.host))")
        // A private window (no space) sees only the shared ones.
        let inPrivate = await store.logins(forHost: "example.com", space: nil)
        precondition(inPrivate.map(\.username) == ["shared"], "got \(inPrivate.map(\.username))")
        // Another site gets nothing.
        let lookalike = await store.logins(forHost: "notexample.com", space: work)
        let suffixTrick = await store.logins(forHost: "evil.example.com.evil.io", space: work)
        precondition(lookalike.isEmpty && suffixTrick.isEmpty, "other sites get nothing")

        // The password comes out only for the one asked for.
        let login = inWork.first { $0.username == "me@work.com" }!
        let first = await store.password(for: login)
        precondition(first == "work-pw")

        // The same login saved again replaces it, and changes the password.
        await store.save([NewLogin(url: "https://www.example.com", username: "me@work.com", password: "new-pw", spaceID: work)])
        let everything = await store.all()
        precondition(everything.filter { $0.username == "me@work.com" }.count == 1, "no duplicate")
        let updated = await store.password(for: login)
        precondition(updated == "new-pw", "password updated")

        // A fresh store on the same service reads what was written (it is the keychain, not memory).
        let again = PasswordStore(service: await store.serviceName)
        let reread = await again.all()
        precondition(reread.count == 4, "re-read \(reread.count)")

        await store.delete(login)
        let gone = await store.password(for: login)
        precondition(gone == nil, "deleted")
        await store.deleteAll()
        let left = await PasswordStore(service: await store.serviceName).all()
        precondition(left.isEmpty, "cleaned up")
        precondition(PasswordStore.host(of: "example.com") == "example.com", "a bare host counts")
        print("PasswordStoreCheck passed")
    }
}
