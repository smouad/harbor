// Reads a Chromium-style profile folder with ChromiumReader and prints what it found as JSON.
// Driven by scripts/tests/chromium_reader_check.py, which builds the folder and does the asserting.
import Foundation

@main
struct ChromiumReaderCheck {
    static func main() throws {
        let args = CommandLine.arguments
        let userData = URL(fileURLWithPath: args[1])
        let browser = ChromiumBrowser(name: "Test", userData: userData, keychainService: "none", keychainAccount: "none")
        let reader = ChromiumReader(browser: browser)
        let key = ChromiumReader.deriveKey(password: Data(args[2].utf8))!
        var out: [String: Any] = [:]
        let profiles = reader.profiles()
        out["profiles"] = profiles.map { "\($0.directory)=\($0.name)" }
        let profile = profiles[0]
        out["cookies"] = reader.cookies(in: profile, key: key).map {
            ["domain": $0.domain, "name": $0.name, "value": $0.value, "secure": $0.isSecure, "httpOnly": $0.isHTTPOnly,
             "session": $0.expiresDate == nil] as [String: Any]
        }
        out["logins"] = reader.logins(in: profile, key: key).map { ["url": $0.url, "user": $0.username, "pass": $0.password] }
        out["history"] = reader.history(in: profile).map { ["url": $0.url, "title": $0.title, "t": Int($0.date.timeIntervalSince1970)] as [String: Any] }
        func describe(_ b: ChromiumBookmark) -> Any {
            switch b {
            case .page(let title, let url): return ["page": title, "url": url]
            case .folder(let title, let items): return ["folder": title, "items": items.map(describe)]
            }
        }
        out["bookmarks"] = reader.bookmarks(in: profile).map(describe)
        out["csv"] = PasswordCSV.make(reader.logins(in: profile, key: key))
        // A wrong key must yield nothing, never garbage.
        let wrong = ChromiumReader.deriveKey(password: Data("not-the-password".utf8))!
        out["wrongKeyCookies"] = reader.cookies(in: profile, key: wrong).filter { $0.name == "sid" }.count
        out["wrongKeyLogins"] = reader.logins(in: profile, key: wrong).count
        let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
