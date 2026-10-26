// Licensed under GPL-3.0. See LICENSE.
//
//  LoginMatching.swift
//  Harbor
//
//  Which saved logins belong to a page. Pure, so scripts/tests/LoginMatchingCheck.swift can
//  compile it on its own.
//

import Foundation

enum LoginMatching {
    /// Second-level suffixes where the site is the label before them, not the last two labels:
    /// `shop.example.co.uk` belongs to `example.co.uk`, and `co.uk` is no one's site.
    private static let compoundSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk", "me.uk",
        "com.au", "net.au", "org.au", "edu.au", "co.nz",
        "co.jp", "ne.jp", "or.jp", "co.kr", "co.in", "net.in", "org.in", "co.id", "co.il", "co.th", "co.za",
        "com.br", "com.ar", "com.mx", "com.co", "com.pe", "com.ve", "com.ec", "com.uy", "com.cl",
        "com.tr", "com.sg", "com.hk", "com.tw", "com.cn", "com.my", "com.ph", "com.pk", "com.vn",
        "com.eg", "com.sa", "com.ng", "com.ua", "com.pt", "com.es", "org.es", "gob.es", "nom.es",
    ]

    /// The part of a host a site owns: `login.example.com` and `www.example.com` are both
    /// `example.com`. A bare IP address or a single label (`localhost`) is its own site.
    static func site(of host: String) -> String {
        let host = host.lowercased()
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count > 2, !labels.allSatisfy({ Int($0) != nil }) else { return host }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if compoundSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// A login saved for `loginHost` is offered on `pageHost` when both are the same site.
    static func matches(loginHost: String, pageHost: String) -> Bool {
        let (login, page) = (loginHost.lowercased(), pageHost.lowercased())
        return login == page || site(of: login) == site(of: page)
    }

    /// Exact host first, so the login made for this very page leads the list.
    static func isExact(loginHost: String, pageHost: String) -> Bool {
        loginHost.lowercased() == pageHost.lowercased()
    }

    /// Pages that may be offered a saved password: https, or plain http only on the machine itself.
    static func isTrusted(scheme: String, host: String) -> Bool {
        let scheme = scheme.lowercased(), host = host.lowercased()
        if scheme == "https" { return true }
        return scheme == "http" && (host == "localhost" || host == "127.0.0.1" || host.hasSuffix(".localhost"))
    }
}
