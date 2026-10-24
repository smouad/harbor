// Licensed under GPL-3.0. See LICENSE.
//
//  ChromeIdentity.swift
//  HarborWeb
//
//  Some sites turn Safari away or serve it a lesser page. A page can present as Chrome instead:
//  Chrome's user agent on the request and in `navigator.userAgent`, plus what sites check beside
//  it (`navigator.userAgentData`, `navigator.vendor`, `window.chrome`). The engine is still WebKit,
//  so a site that needs Chrome-only APIs can still fail; most only read the user agent.
//  Presenting as Chrome everywhere costs more than it gains: Google's bot check flags a Chrome user
//  agent on WebKit and answered a fresh visit with "unusual traffic", where Safari's went through.
//  So pages stay Safari except on the sites the person lists, and on agent pages (while Settings >
//  Developer allows it) on sites a page told the agent its browser is not supported (`learned`,
//  kept across launches). A tool can set it for one page (`PageSession.userAgentOverride`).
//

import Foundation
import WebKit

public enum ChromeIdentity {
    /// Chrome's major version. Its user agent freezes the OS and the minor versions, so only this
    /// moves; keep it within a few releases of the current stable Chrome.
    public static let majorVersion = "142"

    /// Chrome's reduced user agent on a Mac.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/\(majorVersion).0.0.0 Safari/537.36"

    /// Sites that told an agent its browser is not supported; agent pages present as Chrome there.
    public private(set) static var learned: [String] = UserDefaults.standard.stringArray(forKey: learnedKey) ?? []
    private static let learnedKey = "HarborAgentChromeSites"

    /// Remembers the exact host (not its parent domain), newest last, at most 200.
    public static func learn(_ host: String) {
        let site = host.lowercased()
        guard !site.isEmpty, !learned.contains(site) else { return }
        learned = Array((learned + [site]).suffix(200))
        UserDefaults.standard.set(learned, forKey: learnedKey)
    }

    public static func forget(_ host: String) {
        learned.removeAll { $0 == host.lowercased() }
        UserDefaults.standard.set(learned, forKey: learnedKey)
    }

    /// Words a page uses to turn a browser away, in the first part of its text.
    public static func turnsBrowserAway(_ text: String) -> Bool {
        let head = text.prefix(2000).lowercased()
        return awayPhrases.contains { head.contains($0) }
    }

    private static let awayPhrases = [
        "browser is not supported", "browser isn't supported", "browser is no longer supported", "browser not supported",
        "unsupported browser", "use a supported browser", "switch to a supported browser", "safari is not supported",
        "safari isn't supported", "not compatible with your browser", "isn't compatible with your browser",
        "please use google chrome", "please use chrome", "only works in chrome", "only works on chrome",
        "requires google chrome", "update your browser to continue", "upgrade your browser to continue"
    ]

    /// Whether `host` is one of `sites` or under one (a listed domain covers its subdomains).
    public static func matches(host: String?, sites: [String]) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return sites.contains { raw in
            let site = raw.trimmingCharacters(in: .whitespaces).lowercased()
            return !site.isEmpty && (host == site || host.hasSuffix("." + site))
        }
    }

    /// Fills in what Chrome has beside its user agent, only in pages whose user agent is Chrome's,
    /// so it can sit in every page's controller (install once, self-gating).
    static let shim = WKUserScript(source: """
        // Harbor Chrome Identity
        (() => {
            const ua = navigator.userAgent;
            if (!ua.includes("Chrome/\(majorVersion)")) return;
            const brands = [
                { brand: "Chromium", version: "\(majorVersion)" },
                { brand: "Google Chrome", version: "\(majorVersion)" },
                { brand: "Not_A Brand", version: "24" }
            ];
            const high = {
                architecture: "arm", bitness: "64", model: "", platform: "macOS", platformVersion: "15.0.0",
                uaFullVersion: "\(majorVersion).0.0.0", wow64: false, formFactors: ["Desktop"],
                fullVersionList: brands.map(b => ({ brand: b.brand, version: b.version + ".0.0.0" }))
            };
            const data = {
                brands, mobile: false, platform: "macOS",
                getHighEntropyValues: hints => Promise.resolve(Object.assign(
                    { brands, mobile: false, platform: "macOS" },
                    Object.fromEntries((hints || []).filter(h => h in high).map(h => [h, high[h]])))),
                toJSON: () => ({ brands, mobile: false, platform: "macOS" })
            };
            const define = (target, name, value) => {
                try { Object.defineProperty(target, name, { get: () => value, configurable: true }); } catch (e) {}
            };
            define(Navigator.prototype, "userAgentData", data);
            define(Navigator.prototype, "vendor", "Google Inc.");
            if (!window.chrome) {
                // No runtime: a page that finds chrome.runtime tries to talk to an extension.
                window.chrome = { app: { isInstalled: false }, csi: () => ({}), loadTimes: () => ({}) };
            }
        })();
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page)
}

extension PageSession {
    /// Sets the user agent a load of `url` should carry before Harbor starts it, so
    /// `decidePolicyFor` has no load to cancel and start again.
    public func prepareUserAgent(for url: URL) {
        guard let webView else { return }
        let wanted = wantedUserAgent(for: url)
        if (webView.customUserAgent ?? "") != (wanted ?? "") { webView.customUserAgent = wanted }
    }

    /// The user agent the page's next main-frame load should carry.
    func wantedUserAgent(for url: URL) -> String? {
        if let userAgentOverride { return userAgentOverride }
        guard let settings = controller?.settings else { return PlatformUserAgent.custom }
        if isAgentPage, settings.agentPresentsAsChrome, let host = url.host?.lowercased(), ChromeIdentity.learned.contains(host) {
            return ChromeIdentity.userAgent
        }
        if ChromeIdentity.matches(host: url.host, sites: settings.chromeIdentitySites) { return ChromeIdentity.userAgent }
        return PlatformUserAgent.custom
    }
}
