// Licensed under GPL-3.0. See LICENSE.
//
//  PageIconLoader.swift
//  Harbor
//
//  A page's icons as WebKit finds them. WebKit reads the <link> tags itself (and falls back to
//  /favicon.ico when there are none), and through `_WKIconLoadingDelegate`, the interface Safari
//  uses, tells the app each icon it is about to load and hands the bytes back. They are fetched with
//  the page's own cookies and user agent, the moment the head is parsed rather than after the
//  page finishes, and a site that sends several (light and dark, 16 and 180 pixels) sends them all,
//  so the best can be chosen by their real size. This replaced asking the site with a bare request,
//  which a login or a bot check turned away.
//

#if os(macOS)
import AppKit
import Foundation
import SwiftUI
import WebKit
import os

@MainActor
final class PageIconLoader: NSObject {
    private static let log = Logger(subsystem: "com.mouad.harbor", category: "Favicon")

    private weak var session: PageSession?
    private var received: [(candidate: FaviconCandidate, image: PlatformImage)] = []
    private var appliedURL: URL?

    /// True once WebKit has delivered an icon for the page being loaded.
    private(set) var hasDelivered = false

    init(session: PageSession) {
        self.session = session
    }

    /// Makes this the web view's icon loader. The property is weak, so the session keeps the loader.
    func attach(to webView: WKWebView) {
        let setter = NSSelectorFromString("_setIconLoadingDelegate:")
        guard webView.responds(to: setter) else { return Self.log.notice("icon loading interface missing") }
        webView.perform(setter, with: self)
    }

    /// A new page: the icons of the last one are not its own.
    func reset() {
        received = []
        appliedURL = nil
        hasDelivered = false
    }

    // MARK: - From WebKit

    @objc(webView:shouldLoadIconWithParameters:completionHandler:)
    func webView(_ webView: WKWebView, shouldLoadIconWithParameters parameters: AnyObject,
                 completionHandler: @escaping (@escaping (Data?) -> Void) -> Void) {
        guard let url = parameters.value(forKey: "url") as? URL, url.scheme == "http" || url.scheme == "https" else {
            // Nothing to load: WebKit is told to skip it.
            completionHandler { _ in }
            return
        }
        let attributes = parameters.value(forKey: "attributes") as? [String: Any] ?? [:]
        let candidate = FaviconCandidate(
            url: url,
            sizes: attributes["sizes"] as? String ?? "",
            type: (attributes["type"] as? String) ?? (parameters.value(forKey: "mimeType") as? String) ?? "",
            media: attributes["media"] as? String ?? "",
            rel: attributes["rel"] as? String ?? "icon")
        let host = webView.url?.host
        completionHandler { [weak self, weak webView] data in
            guard let data else { return }
            Task { @MainActor in self?.arrived(candidate, data: data, host: host, webView: webView) }
        }
    }

    private func arrived(_ candidate: FaviconCandidate, data: Data, host: String?, webView: WKWebView?) {
        guard let host, let webView, webView.url?.host == host, let image = PlatformImage(data: data) else { return }
        var measured = candidate
        measured.pixelSize = Self.pixelEdge(of: image)
        received.append((measured, image))

        let preferDark = webView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        guard let best = FaviconPick.order(received.map(\.candidate), preferDark: preferDark).first,
              best.url != appliedURL,
              let chosen = received.first(where: { $0.candidate.url == best.url })?.image else { return }
        appliedURL = best.url
        hasDelivered = true
        Self.log.notice("icon for \(host, privacy: .public): \(best.url.lastPathComponent, privacy: .public) \(best.pixelSize ?? 0)px of \(self.received.count) received")
        session?.applyWebKitIcon(chosen, host: host)
    }

    /// The largest edge of any representation, in pixels: an .ico holds several.
    private static func pixelEdge(of image: PlatformImage) -> Int {
        let edges = image.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.filter { $0 > 0 }
        return edges.max() ?? Int(max(image.size.width, image.size.height))
    }
}
#endif
