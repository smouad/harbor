// Licensed under GPL-3.0. See LICENSE.
//
//  AgentTools+Browser.swift
//  Harbor
//
//  The person's own tabs (tabs, when they let agents use them) and how a page presents itself to
//  sites (identity: as Chrome, which most sites that turn Safari away accept, or as Safari).
//

import Foundation
import WebKit
import HarborWeb

extension AgentToolbox {
    static let browserTools: [AgentTool] = [personTabs, identity]

    private static let personTabs = AgentTool(
        "tabs",
        "The person's own tabs, by window: id, title, url, and which one is current. Pass an id (or \"current\") as tab to a page tool to work there. Only when the person allows it in Settings > Developer; under Ask, the first listing and each tab's first use on a site wait for their OK (approval_wait).",
        page: .none
    ) { call in
        let tabs = call.browser.tabs
        guard tabs.settings.agentTabAccess != .off else {
            throw AgentError.invalid("The person has not let agents use their tabs (Settings > Developer)")
        }
        // Titles and addresses can carry mail subjects or reset links, so under Ask listing asks too.
        if tabs.settings.agentTabAccess == .ask {
            switch AgentHub.shared.approvals.personGate(fingerprint: "tabs", about: "Your tabs", reason: "Reads your tabs' titles and addresses",
                                                        action: "See the titles and addresses of your open tabs") {
            case .allowed: break
            case .needsApproval(let request):
                return .json(["ok": false, "needs_approval": request.id, "reason": request.reason, "action": request.action])
            case .refused(let why): throw AgentError.invalid(why)
            }
        }
        let windows = tabs.regularWindows.enumerated().compactMap { index, window -> [String: Any]? in
            // A window showing the Agent space shows no tabs of the person's.
            guard let space = window.spaceID, space != tabs.agentSpaceID else { return nil }
            let items = tabs.displayOrder(in: window).filter { !tabs.isInAgentSpace($0) }.map { id -> [String: Any] in
                let session = tabs.session(for: id)
                var entry: [String: Any] = ["id": id.uuidString, "title": session?.title ?? tabs.item(id)?.displayTitle ?? ""]
                if let url = session?.url ?? tabs.item(id).flatMap({ item -> URL? in
                    if case .tab(let url, _) = item.kind { return url } else { return nil }
                }) { entry["url"] = url.absoluteString }
                if id == window.selectedItemID { entry["current"] = true }
                return entry
            }
            return ["window": index + 1, "space": tabs.space(space)?.name ?? "", "focused": window === call.window, "tabs": items]
        }
        return .untrusted(["access": tabs.settings.agentTabAccess.rawValue, "windows": windows], origin: nil)
    }

    private static let identity = AgentTool(
        "identity",
        "How this page presents itself to sites from its next load: as \"chrome\" (Chrome's user agent and the client hints beside it; the engine is still WebKit), \"safari\", or \"default\" (the person's settings). Use chrome when a site says the browser is not supported. reload: true loads the page again now.",
        properties: [
            "as": ["type": "string", "enum": ["chrome", "safari", "default"]],
            "reload": ["type": "boolean"]
        ],
        required: ["as"]
    ) { call in
        guard let session = call.session, let webView = call.webView else { throw AgentError.noPage }
        // The person's own tab keeps the identity they chose for it.
        guard session.isAgentPage else { throw AgentError.invalid("identity works on Agent space tabs only") }
        switch try call.args.required("as") {
        case "chrome": session.userAgentOverride = ChromeIdentity.userAgent
        case "safari": session.userAgentOverride = PlatformUserAgent.custom
        case "default": session.userAgentOverride = nil
        default: throw AgentError.invalid("as is chrome, safari or default")
        }
        if call.args.bool("reload") == true, let url = webView.url {
            _ = await AgentPageWait.open(webView, url: url, timeout: call.waitBudget(nil, fallback: 20))
        }
        let current = (try? await webView.evaluateJavaScript("navigator.userAgent")) as? String ?? ""
        return .json(["as": call.args.string("as") ?? "", "userAgent": current,
                      "note": call.args.bool("reload") == true ? "Reloaded" : "Applies from the next load"])
    }
}
