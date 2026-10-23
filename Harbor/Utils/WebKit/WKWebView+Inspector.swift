// Licensed under GPL-3.0. See LICENSE.
//
//  WKWebView+Inspector.swift
//  Harbor
//
//  The docked Web Inspector lives in the page's own container: WebKit adds its view
//  (`WKInspectorWKWebView`) beside the page and splits the space between them. Harbor's layout
//  code used to treat it as a stale view, removing it and stretching the page back over the
//  space on every update, and WebKit put it back each time: the inspector flickered and never
//  showed its contents while the page scrolled.
//

import AppKit
import WebKit

extension NSView {
    /// WebKit's docked inspector view. Layout code leaves it, and the page beside it, alone.
    var isWebInspectorView: Bool { NSStringFromClass(type(of: self)).contains("WKInspector") }
}

extension WKWebView {
    /// `_inspector`, WebKit's SPI for the page's Web Inspector; nil on a WebKit without it.
    private var webInspector: NSObject? {
        let selector = NSSelectorFromString("_inspector")
        guard responds(to: selector) else { return nil }
        return perform(selector)?.takeUnretainedValue() as? NSObject
    }

    var isWebInspectorVisible: Bool {
        guard let inspector = webInspector, inspector.responds(to: NSSelectorFromString("isVisible")) else { return false }
        return (inspector.value(forKey: "isVisible") as? Bool) == true
    }

    /// Closes the page's inspector when another page takes its container, so it is not left
    /// docked beside a page it does not belong to.
    func closeWebInspector() {
        guard isWebInspectorVisible, let inspector = webInspector,
              inspector.responds(to: NSSelectorFromString("close")) else { return }
        inspector.perform(NSSelectorFromString("close"))
    }
}
