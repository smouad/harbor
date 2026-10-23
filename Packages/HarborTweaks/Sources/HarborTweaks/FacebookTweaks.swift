// Licensed under GPL-3.0. See LICENSE.
//
//  FacebookTweaks.swift
//  Harbor
//
//  Created by Claude on 16/09/2026.
//

import Foundation
import HarborBlocker
import HarborSettings
import OSLog
import WebKit

private let fbTweaksLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Harbor", category: "FacebookTweaks")

/// Hides the Reels carousel and suggested content in Facebook's news feed. Shares
/// `facebook-feed-prune.js` with the content blocker: this copy sets the reels and suggested flags,
/// the blocker's copy sets the ad flag, and whichever runs first installs the one JSON.parse hook.
@MainActor
public enum FacebookTweaks {
    private static let marker = "// Harbor Facebook Tweaks"

    private static let filter: String? = {
        // Shared with the content blocker, so it lives in HarborBlocker's resource bundle.
        guard let source = AdvancedRulesEngine.bundledSource("facebook-feed-prune") else {
            fbTweaksLog.warning("Failed to load facebook-feed-prune.js from HarborBlocker")
            return nil
        }
        return source
    }()

    /// Main-frame navigation hook, next to YouTubeTweaks. Settings apply on the next page load.
    public static func apply(for url: URL, in webView: WKWebView, settings: HarborSettingsService) {
        let source = isFacebook(url.host) ? userScriptSource(settings) : nil
        let ucc = webView.configuration.userContentController
        // Read everything from the lazily bridged array before removeAllUserScripts (Release-only trap).
        let all = ucc.userScripts
        let others = all.harborOwned.filter { !$0.source.hasPrefix(marker) }
        let current = all.first { $0.source.hasPrefix(marker) }?.source
        guard current != source else { return }
        ucc.removeAllUserScripts()
        others.forEach { ucc.addUserScript($0) }
        if let source {
            // Page world: the hook has to replace the JSON.parse Facebook's own code calls.
            ucc.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        }
    }

    private static func userScriptSource(_ settings: HarborSettingsService) -> String? {
        guard let filter, settings.facebookHideReels || settings.facebookHideSuggested else { return nil }
        return """
        \(marker)
        (function(){ if (!/(^|\\.)facebook\\.com$/.test(location.hostname)) return;
        var f = window.__harborFBFilter = window.__harborFBFilter || {};
        f.reels = \(settings.facebookHideReels); f.suggested = \(settings.facebookHideSuggested);
        \(filter)
        })();
        """
    }

    private static func isFacebook(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com")
    }
}
