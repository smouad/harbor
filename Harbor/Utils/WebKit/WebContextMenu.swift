// Licensed under GPL-3.0. See LICENSE.
//
//  WebContextMenu.swift
//  Harbor
//
//  Created by Codex on 09/02/2025.
//

import AppKit
import UniformTypeIdentifiers
import WebKit
import HarborTabsCore
import HarborWeb

enum WebContextMenuItem {
    case pageBack
    case pageForward
    case pageReload
    case pageCopyAddress
    case pageSaveAs
    case pagePrint
    case pageCast
    case pageTranslate
    case pageViewSource

    /// Every enabled extension's own items (`contextMenus`), one item or submenu each.
    case extensions

    case linkOpenInNewTab
    case linkCopy

    case imageOpenInNewTab
    case imageSaveToDownloads
    case imageSaveAs
    case imageCopyAddress

    case textCopy

    case separator

    case systemLookUp
    case systemTranslate
    case systemShare
    case systemInspect
    case systemImageCopy

    @MainActor
    static func buildMenuItems(
        for payload: WebContextMenuPayload,
        on webView: FocusableWKWebView,
        baseMenu: NSMenu
    ) -> [NSMenuItem] {
        let items = cleanedItems(content(for: payload))
        let menuItems = items.flatMap { $0.makeMenuItems(on: webView, payload: payload, baseMenu: baseMenu) }
        // An extension that adds nothing leaves its separators behind; drop the doubles.
        return menuItems.enumerated().filter { index, item in
            !(item.isSeparatorItem && (index == 0 || menuItems[index - 1].isSeparatorItem))
        }.map(\.element)
    }

    private static func content(for payload: WebContextMenuPayload) -> [WebContextMenuItem] {
        switch payload {
        case .page:
            // Arc's page menu: history, then what to do with the page, then extensions, then
            // the developer's two.
            return [
                .pageBack, .pageForward, .pageReload,
                .separator,
                .pageSaveAs, .pagePrint, .pageCast, .pageTranslate,
                .separator,
                .extensions,
                .separator,
                .pageViewSource, .systemInspect
            ]
        case .textSelection:
            return [.systemLookUp, .systemTranslate, .textCopy, .separator, .systemShare, .separator, .extensions, .separator, .systemInspect]
        case .link:
            return [.linkOpenInNewTab, .separator, .linkCopy, .separator, .systemShare, .separator, .extensions, .separator, .systemInspect]
        case .image:
            return [
                .imageOpenInNewTab,
                .separator,
                .imageSaveToDownloads,
                .imageSaveAs,
                .separator,
                .imageCopyAddress,
                .systemImageCopy,
                .separator,
                .systemShare,
                .separator,
                .extensions,
                .separator,
                .systemInspect
            ]
        case .multiple(let payloads):
            return payloads.flatMap { content(for: $0) }
        case .ignored:
            return []
        }
    }

    private static func cleanedItems(_ items: [WebContextMenuItem]) -> [WebContextMenuItem] {
        var result: [WebContextMenuItem] = []
        var previousSeparator = false

        for item in items {
            if item == .separator {
                if previousSeparator { continue }
                previousSeparator = true
            } else {
                previousSeparator = false
            }
            result.append(item)
        }

        while result.last == .separator {
            result.removeLast()
        }

        return result
    }

    @MainActor
    private func makeMenuItems(
        on webView: FocusableWKWebView,
        payload: WebContextMenuPayload,
        baseMenu: NSMenu
    ) -> [NSMenuItem] {
        switch self {
        case .extensions:
            guard let session = webView.owningSession else { return [] }
            return ExtensionManager.shared.contextMenuItems(for: session)
        case .systemInspect:
            // WebKit adds its own only when developer extras are on; Harbor always offers it.
            if let existing = baseMenu.items.first(where: { $0.identifier == .webKitInspectElement }) {
                existing.title = "Inspect"
                return [existing]
            }
            return [HandlerMenuItem(title: "Inspect") { [weak webView] _ in webView?.openInspector() }]
        default:
            return makeMenuItem(on: webView, payload: payload, baseMenu: baseMenu).map { [$0] } ?? []
        }
    }

    @MainActor
    private func makeMenuItem(
        on webView: FocusableWKWebView,
        payload: WebContextMenuPayload,
        baseMenu: NSMenu
    ) -> NSMenuItem? {
        switch self {
        case .separator:
            return NSMenuItem.separator()
        case .systemLookUp, .systemTranslate, .systemShare, .systemInspect, .systemImageCopy:
            guard let identifier = systemIdentifier,
                  let existing = baseMenu.items.first(where: { $0.identifier == identifier })
            else { return nil }
            return existing
        default:
            guard let title = title(on: webView) else { return nil }
            let item = HandlerMenuItem(title: title) { [weak webView] _ in
                guard let webView else { return }
                self.performAction(on: webView, payload: payload)
            }
            item.isEnabled = isEnabled(context: webView)
            return item
        }
    }

    @MainActor
    private func title(on webView: FocusableWKWebView) -> String? {
        switch self {
        case .pageBack: return "Back"
        case .pageForward: return "Forward"
        case .pageReload: return "Reload"
        case .pageCopyAddress: return "Copy Page Address"
        case .pageSaveAs: return "Save As…"
        case .pagePrint: return "Print…"
        case .pageCast: return "Cast…"
        case .pageTranslate:
            guard let session = webView.owningSession else { return "Translate Page" }
            return session.isTranslated ? "Show Original" : "Translate to \(session.translationTargetName)"
        case .pageViewSource: return "View Page Source"
        case .linkOpenInNewTab: return "Open Link in New Tab"
        case .linkCopy: return "Copy Link"
        case .imageOpenInNewTab: return "Open Image in New Tab"
        case .imageSaveToDownloads: return "Save Image to Downloads"
        case .imageSaveAs: return "Save Image As..."
        case .imageCopyAddress: return "Copy Image Address"
        case .textCopy: return "Copy"
        case .separator, .systemLookUp, .systemTranslate, .systemShare, .systemInspect, .systemImageCopy, .extensions:
            return nil
        }
    }

    private var systemIdentifier: NSUserInterfaceItemIdentifier? {
        switch self {
        case .systemLookUp: return .webKitTextLookUp
        case .systemTranslate: return .webKitTextTranslate
        case .systemShare: return .webKitSharing
        case .systemInspect: return .webKitInspectElement
        case .systemImageCopy: return .webKitCopyImage
        default: return nil
        }
    }

    @MainActor
    private func isEnabled(context: FocusableWKWebView) -> Bool {
        switch self {
        case .pageBack: return context.canGoBack || context.owningSession?.canGoBackOrReturn == true
        case .pageForward: return context.canGoForward
        case .pageTranslate: return context.owningSession?.canTranslate == true
        // AirPlay plays a video element; a page without one has nothing to send.
        case .pageCast: return context.owningSession?.hasVideoContent == true
        default: return true
        }
    }

    @MainActor
    private func performAction(on webView: FocusableWKWebView, payload: WebContextMenuPayload) {
        switch self {
        case .pageBack:
            if let session = webView.owningSession { session.goBack(in: webView) } else { webView.goBack() }
        case .pageForward:
            webView.goForward()
        case .pageTranslate:
            webView.owningSession?.toggleTranslation()
        case .pageReload:
            webView.reload()
        case .pageSaveAs:
            webView.savePageAs()
        case .pagePrint:
            webView.harborPrint()
        case .pageCast:
            webView.showAirPlayPicker()
        case .pageViewSource:
            webView.openInspector(showingSource: true)
        case .pageCopyAddress:
            if let url = payload.pageURL ?? webView.owningSession?.url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .linkOpenInNewTab:
            if let url = payload.linkURL {
                webView.openLinkInNewTab(url)
            }
        case .linkCopy:
            if let url = payload.linkURL {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .imageOpenInNewTab:
            if let url = payload.imageURL {
                webView.openLinkInNewTab(url)
            }
        case .imageSaveToDownloads:
            webView.downloadImage(identifier: payload.imageSourceString)
        case .imageSaveAs:
            webView.downloadImage(identifier: payload.imageSourceString, promptForLocation: true)
        case .imageCopyAddress:
            if let url = payload.imageURL {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
        case .textCopy:
            if let text = payload.textSelection {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        default:
            break
        }
    }
}

@MainActor
final class HandlerMenuItem: NSMenuItem {
    private let handler: (NSMenuItem) -> Void

    init(title: String, handler: @escaping (NSMenuItem) -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(handleAction(_:)), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleAction(_ sender: NSMenuItem) {
        handler(sender)
    }
}

extension FocusableWKWebView {
    /// Opens `url` in the background in the owning page's window and space. A middle click
    /// on a link takes the same path, so the placement and scheme rules live on the session.
    func openLinkInNewTab(_ url: URL) {
        owningSession?.openInNewTab(url)
    }

    func downloadImage(from url: URL?, promptForLocation: Bool = false) {
        guard let identifier = url?.absoluteString else { return }
        handleImageDownload(identifier: identifier, promptForLocation: promptForLocation)
    }

    func downloadImage(identifier: String?, promptForLocation: Bool = false) {
        guard let identifier else { return }
        handleImageDownload(identifier: identifier, promptForLocation: promptForLocation)
    }
}

// MARK: - Page actions

extension FocusableWKWebView {
    /// The docked Web Inspector, through WebKit's `_inspector` SPI, as Cmd+Opt+I opens it.
    /// `showingSource` opens it on the page's resources with the document selected, which is
    /// how Safari shows a page's source. A WebKit without the SPI does nothing.
    func openInspector(showingSource: Bool = false) {
        // Release builds leave developer extras off, and the inspector shows nothing for a page
        // that is not inspectable.
        isInspectable = true
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector),
              let inspector = perform(selector)?.takeUnretainedValue() as? NSObject else { return }
        inspector.perform(NSSelectorFromString("show"))
        inspector.perform(NSSelectorFromString("attach"))
        let resources = NSSelectorFromString("showResources")
        if showingSource, inspector.responds(to: resources) { inspector.perform(resources) }
    }

    /// Saves the page as a Web Archive, or as its HTML when the name ends in .html.
    func savePageAs() {
        guard let window else { return }
        let panel = NSSavePanel()
        let base = (title?.isEmpty == false ? title! : url?.host ?? "Page")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = base + ".webarchive"
        panel.allowedContentTypes = [.webArchive, .html]
        panel.canSelectHiddenExtension = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url, let self else { return }
            if destination.pathExtension.lowercased().hasPrefix("htm") {
                Task { @MainActor in
                    let html = try? await self.callAsyncJavaScript(
                        "return document.documentElement.outerHTML", contentWorld: .defaultClient) as? String
                    guard let data = html.flatMap({ "<!DOCTYPE html>\n" + $0 }).flatMap({ $0.data(using: .utf8) }) else { return }
                    try? data.write(to: destination, options: .atomic)
                }
            } else {
                self.createWebArchiveData { result in
                    if case .success(let data) = result { try? data.write(to: destination, options: .atomic) }
                }
            }
        }
    }

    /// Opens the AirPlay picker for the page's video: the one playing, else the largest.
    /// Script the app runs counts as a user gesture, which the picker needs.
    func showAirPlayPicker() {
        let script = """
        const videos = Array.from(document.querySelectorAll('video'));
        const playing = videos.find(v => !v.paused);
        const largest = videos.sort((a, b) => b.clientWidth * b.clientHeight - a.clientWidth * a.clientHeight)[0];
        const video = playing || largest;
        if (video && video.webkitShowPlaybackTargetPicker) { video.webkitShowPlaybackTargetPicker(); return true; }
        return false;
        """
        Task { @MainActor in _ = try? await callAsyncJavaScript(script, contentWorld: .defaultClient) }
    }
}
