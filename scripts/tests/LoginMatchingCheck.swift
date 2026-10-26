// swiftc -parse-as-library Harbor/Managers/PasswordManager/LoginMatching.swift scripts/tests/LoginMatchingCheck.swift -o /tmp/lmc && /tmp/lmc
import Foundation

@main
struct LoginMatchingCheck {
    static func main() {
        precondition(LoginMatching.site(of: "login.example.com") == "example.com")
        precondition(LoginMatching.site(of: "www.example.com") == "example.com")
        precondition(LoginMatching.site(of: "example.com") == "example.com")
        precondition(LoginMatching.site(of: "shop.example.co.uk") == "example.co.uk")
        precondition(LoginMatching.site(of: "evaseguros.es") == "evaseguros.es")
        precondition(LoginMatching.site(of: "app.evaseguros.es") == "evaseguros.es")
        precondition(LoginMatching.site(of: "192.168.1.20") == "192.168.1.20")
        precondition(LoginMatching.site(of: "localhost") == "localhost")

        precondition(LoginMatching.matches(loginHost: "www.example.com", pageHost: "login.example.com"))
        precondition(LoginMatching.matches(loginHost: "example.com", pageHost: "example.com"))
        // Different sites never share a login, however alike the names.
        precondition(!LoginMatching.matches(loginHost: "example.com", pageHost: "example.org"))
        precondition(!LoginMatching.matches(loginHost: "example.com", pageHost: "notexample.com"))
        precondition(!LoginMatching.matches(loginHost: "example.com", pageHost: "example.com.evil.io"))
        // Two unrelated sites under one compound suffix stay apart.
        precondition(!LoginMatching.matches(loginHost: "a.co.uk", pageHost: "b.co.uk"))

        precondition(LoginMatching.isExact(loginHost: "Example.com", pageHost: "example.com"))
        precondition(!LoginMatching.isExact(loginHost: "www.example.com", pageHost: "example.com"))

        precondition(LoginMatching.isTrusted(scheme: "https", host: "example.com"))
        precondition(!LoginMatching.isTrusted(scheme: "http", host: "example.com"))
        precondition(LoginMatching.isTrusted(scheme: "http", host: "localhost"))
        precondition(!LoginMatching.isTrusted(scheme: "file", host: ""))
        print("LoginMatchingCheck passed")
    }
}
