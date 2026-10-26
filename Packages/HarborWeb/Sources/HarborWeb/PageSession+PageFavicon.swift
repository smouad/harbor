// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+PageFavicon.swift
//  Harbor
//
//  A page's own icon, read from the page that is open. FaviconFinder and the root /favicon.ico
//  ask the site with a bare request: no cookies, no Referer, no session. A site behind a login
//  (a 401 for everyone not signed in), a bot check, or one that serves its icon only from a
//  <link> built by script gave nothing that way, and its tab kept the globe. The page knows its
//  own <link> tags, and its data store holds the cookies the site expects.
//

import Foundation
import SwiftUI
import WebKit

extension PageSession {
    private static let faviconWorld = WKContentWorld.world(name: "HarborFavicon")

    /// Reads the icon links out of the page (waiting a couple of seconds for a script-built one),
    /// then downloads them best first with the page's cookies and user agent. Nil when the page
    /// declares none that load and `/favicon.ico` does not either.
    func iconFromPage(_ webView: WKWebView, pageURL: URL) async -> PlatformImage? {
        guard let reply = try? await webView.callAsyncJavaScript(
            Self.faviconScript, arguments: [:], in: nil, contentWorld: Self.faviconWorld) as? [String: Any]
        else { return nil }
        let base = (reply["base"] as? String).flatMap(URL.init(string:)) ?? pageURL
        var candidates = (reply["links"] as? [[String: Any]] ?? []).compactMap { link -> FaviconCandidate? in
            guard let href = link["href"] as? String, let url = URL(string: href, relativeTo: base)?.absoluteURL,
                  url.scheme == "http" || url.scheme == "https" else { return nil }
            return FaviconCandidate(url: url, sizes: link["sizes"] as? String ?? "", type: link["type"] as? String ?? "",
                                    media: link["media"] as? String ?? "", rel: link["rel"] as? String ?? "icon")
        }
        // What every browser tries when the page says nothing.
        if let root = URL(string: "/favicon.ico", relativeTo: base)?.absoluteURL {
            candidates.append(FaviconCandidate(url: root, sizes: "", type: "image/x-icon", media: "", rel: "icon"))
        }

        #if os(macOS)
        let preferDark = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        #else
        let preferDark = false
        #endif
        let userAgent = (reply["ua"] as? String) ?? webView.customUserAgent
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for candidate in FaviconPick.order(candidates, preferDark: preferDark).prefix(4) {
            if let image = await Self.download(candidate.url, referer: base, userAgent: userAgent, cookies: cookies) {
                return image
            }
        }
        return nil
    }

    /// One icon, as the page would have asked for it: its cookies, its user agent, and the page
    /// as Referer. Cookies are sent by hand so this session keeps none of its own, and nothing
    /// a site sets here reaches the shared store or another space.
    private static func download(_ url: URL, referer: URL, userAgent: String?, cookies: [HTTPCookie]) async -> PlatformImage? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        let sent = cookies.filter { cookie in sends(cookie, to: url) }
        for (field, value) in HTTPCookie.requestHeaderFields(with: sent) { request.setValue(value, forHTTPHeaderField: field) }

        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        guard let (data, response) = try? await URLSession(configuration: config).data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              (1...1_000_000).contains(data.count) else { return nil }
        // A login page served in place of the icon is HTML, not an image.
        if let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased(), type.contains("text/html") { return nil }
        return PlatformImage(data: data)
    }

    /// Whether a browser would attach `cookie` to a request for `url`.
    private static func sends(_ cookie: HTTPCookie, to url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        let domain = cookie.domain.lowercased()
        let hostMatches = domain.hasPrefix(".") ? (host == String(domain.dropFirst()) || host.hasSuffix(domain)) : host == domain
        guard hostMatches else { return false }
        if cookie.isSecure, url.scheme != "https" { return false }
        let path = url.path.isEmpty ? "/" : url.path
        return path.hasPrefix(cookie.path)
    }

    /// Runs in the page, in its own world: the page cannot see it or change what it returns.
    private static let faviconScript = """
    const wanted = /(^|\\s)(icon|shortcut|apple-touch-icon|apple-touch-icon-precomposed)(\\s|$)/i;
    const collect = () => Array.from(document.querySelectorAll('link[rel][href]'))
        .filter(link => wanted.test(link.rel))
        .map(link => ({ href: link.href, sizes: link.getAttribute('sizes') || '', type: link.type || '',
                        media: link.media || '', rel: link.rel }));
    let links = collect();
    // A single-page app builds its <link> after load; give it a moment before giving up.
    for (let attempt = 0; attempt < 6 && links.length === 0; attempt++) {
        await new Promise(resolve => setTimeout(resolve, 400));
        links = collect();
    }
    return { links, ua: navigator.userAgent, base: location.href };
    """
}
