// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPolicyCheck.swift
//
//  Checks AgentKit's browser-free rules: task scope, secret placeholders, sensitive actions and
//  step templates. Run:
//    xcrun swiftc -parse-as-library Harbor/Managers/AgentKit/AgentPolicy.swift Harbor/Managers/AgentKit/AgentExpression.swift scripts/tests/AgentPolicyCheck.swift -o /tmp/apc && /tmp/apc
//

import Foundation

@main
struct AgentPolicyCheck {
    static func main() {
        scope()
        placeholders()
        sensitivity()
        templates()
        uploadPaths()
        expressions()
        linkedInVolume()
        print("AgentPolicyCheck passed")
    }

    static func linkedInVolume() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("li-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let start = Date(timeIntervalSince1970: 1_000_000)
        let usage = AgentLinkedInUsage(file: file)
        for i in 0..<10 { try! usage.claim(.search, now: start.addingTimeInterval(Double(i))) }
        precondition((try? usage.claim(.search, now: start.addingTimeInterval(60))) == nil, "the 11th search in an hour is refused")
        try! usage.claim(.profile, now: start.addingTimeInterval(60))
        precondition((try? usage.claim(.search, now: start.addingTimeInterval(3_601))) != nil, "an hour later searches are allowed again")
        let reloaded = AgentLinkedInUsage(file: file)
        for i in 0..<29 { try! reloaded.claim(.profile, now: start.addingTimeInterval(4_000 + Double(i))) }
        precondition((try? reloaded.claim(.profile, now: start.addingTimeInterval(5_000))) == nil, "30 profiles a day, counted across launches")
        precondition((try? reloaded.claim(.profile, now: start.addingTimeInterval(86_500))) != nil, "a day later profiles are allowed again")
    }

    static func expressions() {
        let scopes: [String: Any] = [
            "vars": ["count": NSNumber(value: 3), "name": "Ada", "rows": [["n": 1], ["n": 2]], "on": NSNumber(value: true),
                     "empty": "", "none": NSNull()],
            "input": ["limit": NSNumber(value: 2)],
            "item": ["title": "Hi"]
        ]
        func value(_ e: String) -> Any { try! AgentExpression.evaluate(e, scopes: scopes) }
        func yes(_ e: String) -> Bool { AgentExpression.truthy(value(e)) }
        precondition(yes("vars.count > input.limit"))
        precondition(yes("vars.count == 3"), "a decoded number equals a literal")
        precondition(!yes("vars.count == \"3\""), "strict: a number never equals text")
        precondition(yes("vars.name == 'Ada' && !vars.empty"))
        precondition(yes("vars.rows.length == 2 && vars.rows.1.n == 2"), "length and list indexes")
        precondition(yes("item.title == \"Hi\""), "a foreach alias at the top level")
        precondition(yes("vars.on"), "a decoded true is true")
        precondition(!yes("vars.none") && yes("vars.none == null"))
        precondition(AgentExpression.text(value("vars.count - 1")) == "2", "a minus after a value subtracts")
        precondition(AgentExpression.text(value("-2 + 5")) == "3")
        precondition(AgentExpression.text(value("'n=' + vars.count")) == "n=3", "+ with text joins")
        precondition(AgentExpression.text(value("(1 + 2) * 3")) == "9")
        precondition(AgentExpression.text(value("(vars.missing || 0) + 1")) == "1", "|| gives the operand, as in JavaScript")
        precondition(AgentExpression.text(value("vars.name && vars.count")) == "3")
        precondition(yes("vars.missing == null") && !yes("item.skip"), "a field an object lacks reads null")
        precondition((try? AgentExpression.evaluate("nothing.x", scopes: scopes)) == nil, "an unknown name is an error")
        precondition((try? AgentExpression.evaluate("vars.name.first", scopes: scopes)) == nil, "text has no fields")
        precondition((try? AgentExpression.evaluate("vars.count +", scopes: scopes)) == nil)
        precondition((try? AgentExpression.evaluate("alert(1)", scopes: scopes)) == nil, "no calls")
        precondition((try? AgentExpression.evaluate("vars.count = 4", scopes: scopes)) == nil, "no assignment")
    }

    static func uploadPaths() {
        let home = "/Users/p"
        let ok = { (path: String) in AgentUploadPaths.refusal(path, home: home) == nil }
        precondition(ok("/Users/p/Documents/cv.pdf"))
        precondition(ok("/Users/p/Desktop/a b.png"))
        precondition(ok("/private/tmp/x.txt"), "temporary files are fine")
        precondition(ok("/Users/p/Library/Mobile Documents/com~apple~CloudDocs/x.pdf"), "iCloud Drive is the person's files")
        precondition(ok("/Users/p/Library/CloudStorage/Dropbox/x.pdf"))
        precondition(ok("/Users/p/Projects/.env.example"), "a dotfile deeper down is only refused at the top")
        precondition(!ok("/Users/p/.ssh/id_ed25519"))
        precondition(!ok("/Users/p/.zsh_history"))
        precondition(!ok("/Users/p/.aws/credentials"))
        precondition(!ok("/Users/p/Library/Keychains/login.keychain-db"))
        precondition(!ok("/Users/p/Library/Application Support/com.mouad.harbor/dev-mcp-token"))
        precondition(!ok("/Users/p/Library/Cookies/Cookies.binarycookies"))
        precondition(!ok("/Users/p/Library"), "the folder itself")
        precondition(!ok("/private/etc/master.passwd"))
        precondition(!ok("/etc/hosts"))
        precondition(!ok("/private/var/db/x"))
        precondition(!ok("/Library/Keychains/System.keychain"))
    }

    static func scope() {
        let allows = { (url: String, origins: [String]) in AgentScope.allows(URL(string: url)!, origins: origins) }
        precondition(allows("https://evil.example/", []), "no list allows anything")
        precondition(allows("https://shop.example.com/cart", ["example.com"]), "a bare host covers subdomains")
        precondition(allows("https://example.com/", ["example.com"]))
        precondition(!allows("https://example.com.evil.net/", ["example.com"]), "suffix must be a whole label")
        precondition(!allows("https://notexample.com/", ["example.com"]), "suffix must be a whole label")
        precondition(allows("https://a.b.example.com/", ["*.example.com"]))
        precondition(allows("https://a.example.com/", [".example.com"]))
        precondition(allows("http://127.0.0.1:18765/x", ["127.0.0.1"]), "a host entry ignores the port")
        precondition(allows("http://localhost:3000/", ["http://localhost:3000"]), "an origin matches exactly")
        precondition(!allows("http://localhost:3001/", ["http://localhost:3000"]), "an origin's port must match")
        precondition(!allows("https://localhost:3000/", ["http://localhost:3000"]), "an origin's scheme must match")
        precondition(allows("about:blank", ["example.com"]), "about:blank carries no origin")
        precondition(allows("blob:https://example.com/123", ["example.com"]), "a blob: URL carries its maker's origin")
        precondition(!allows("blob:https://evil.net/123", ["example.com"]))
        precondition(!allows("data:text/html,hi", ["example.com"]), "a scoped tab opens no data: document")
        precondition(allows("data:text/html,hi", []))
        precondition(!allows("https://other.org/", ["example.com", "example.net"]))
        precondition(allows("https://WWW.Example.COM/", ["example.com"]), "hosts compare case-insensitively")
        precondition(allows("https://example.com/", ["example.com/some/path"]), "a path in an entry is ignored")
    }

    static func placeholders() {
        precondition(AgentPlaceholders.names(in: "{{secret:pw}} and {{ secret : api.key }}") == ["pw", "api.key"])
        precondition(AgentPlaceholders.names(in: "plain {{other}} text").isEmpty)
        let values = ["pw": "hunter2", "k": "K"]
        precondition(AgentPlaceholders.fill("user:{{secret:pw}}!{{secret:k}}", lookup: { values[$0] }) == "user:hunter2!K")
        precondition(AgentPlaceholders.fill("{{secret:missing}}", lookup: { values[$0] }) == nil, "an unknown secret types nothing")
        precondition(AgentPlaceholders.fill("no secrets", lookup: { _ in nil }) == "no secrets")
        let typed: [String: Set<String>] = ["pw": ["p@ss word/1\"x"]]
        let scrubbed = AgentPlaceholders.scrub(
            "url=/login?pw=p%40ss+word%2F1%22x body={\"pw\":\"p@ss word/1\\\"x\"} raw p@ss word/1\"x", values: typed)
        precondition(!scrubbed.contains("p@ss") && !scrubbed.contains("p%40ss"), scrubbed)
        precondition(scrubbed.components(separatedBy: "{{secret:pw}}").count == 4, scrubbed)
        precondition(AgentPlaceholders.scrub("abc and abc", values: ["s": ["abc"]]) == "abc and abc", "short values are left")
        let bang: [String: Set<String>] = ["pw": ["Passw0rd!(x)*"]]
        for echoed in ["?pw=Passw0rd!(x)*", "?pw=Passw0rd%21%28x%29%2A", "pw=Passw0rd%21%28x%29*"] {
            let out = AgentPlaceholders.scrub(echoed, values: bang)
            precondition(!out.contains("Passw0rd"), out)
        }
        precondition(AgentPlaceholders.scrub("pw=Passw0rd%21%28x%29%2a", values: bang).contains("{{secret:pw}}"), "lowercase hex")
        precondition(AgentPlaceholders.scrub("a=old-secret b=new-secret", values: ["k": ["old-secret", "new-secret"]]) == "a={{secret:k}} b={{secret:k}}", "every value a name had")
    }

    static func sensitivity() {
        func reason(_ action: String, role: String = "button", name: String = "", type: String = "", key: String = "", secret: Bool = false) -> String? {
            var facts = AgentActionFacts(action: action)
            facts.role = role
            facts.name = name
            facts.inputType = type
            facts.key = key
            facts.typedSecret = secret
            facts.host = "shop.example"
            return AgentSensitivity.reason(for: facts)
        }
        precondition(reason("click", name: "Place order") == "Spends money")
        precondition(reason("click", name: "Buy now") == "Spends money")
        precondition(reason("click", name: "Delete repository") == "Deletes something")
        precondition(reason("click", name: "Send message") == "Sends or publishes something")
        precondition(reason("click", name: "Sign in") == "Signs in or grants access")
        precondition(reason("click", name: "Display settings") == nil, "display is not pay")
        precondition(reason("click", name: "Repost options") == nil, "repost is not post")
        precondition(reason("click", name: "Next page") == nil)
        precondition(reason("submit", name: "") == "Submits a form")
        precondition(reason("fill", role: "textbox", name: "Password", type: "password") != nil, "a password the vault did not supply")
        precondition(reason("fill", role: "textbox", name: "Password", type: "password", secret: true) == nil, "a vault password is fine")
        precondition(reason("fill", role: "textbox", name: "Card number") == "Enters payment details")
        precondition(reason("fill", role: "textbox", name: "Search") == nil)
        precondition(reason("press", role: "textbox", name: "Password", type: "password", key: "Enter") == "Signs in")
        precondition(reason("scroll") == nil)
        precondition(reason("eval", role: "", name: "") == "Runs a script on shop.example", "scripts ask once per task")
        var framed = AgentActionFacts(action: "click")
        framed.opaqueTarget = true
        let opaque = AgentSensitivity.reason(for: framed)!
        precondition(opaque == "Clicks inside something Harbor cannot see into" && AgentSensitivity.isSingleUse(opaque))
        precondition(AgentSensitivity.isSingleUse("Spends money") && !AgentSensitivity.isSingleUse("Signs in or grants access"))
        precondition(AgentSensitivity.matchesWord("pay", in: "display then pay now"), "a later whole-word hit counts")
    }

    static func templates() {
        let scopes: [String: Any] = ["vars": ["q": "milk", "n": 3, "list": ["a", "b"], "user": ["name": "Ada"]]]
        precondition(AgentTemplate.fill("${vars.q}", scopes: scopes) as? String == "milk")
        precondition(AgentTemplate.fill("${vars.n}", scopes: scopes) as? Int == 3, "a lone placeholder keeps its type")
        precondition((AgentTemplate.fill("${vars.list}", scopes: scopes) as? [String]) == ["a", "b"])
        precondition(AgentTemplate.fill("buy ${vars.n} x ${vars.q}", scopes: scopes) as? String == "buy 3 x milk")
        precondition(AgentTemplate.fill("hi ${vars.user.name}", scopes: scopes) as? String == "hi Ada")
        precondition(AgentTemplate.fill("${vars.list.1}", scopes: scopes) as? String == "b")
        precondition(AgentTemplate.fill("${vars.nope} stays", scopes: scopes) as? String == "${vars.nope} stays")
        let step = AgentTemplate.fill(["action": "fill", "text": "${vars.q}", "nested": ["x": "${vars.n}"]], scopes: scopes) as! [String: Any]
        precondition(step["text"] as? String == "milk" && (step["nested"] as? [String: Any])?["x"] as? Int == 3)
    }
}
