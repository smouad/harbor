// Licensed under GPL-3.0. See LICENSE.
//
//  PageSession+UnloadSnapshot+macOS.swift
//  HarborWeb
//
//  Captures `unloadSnapshot` before an automatic unload. JPEG at 1x keeps it near 150 KB for a
//  full window, against the hundreds of megabytes the live page held.
//

#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

extension PageSession {
    /// Keeps what the page shows now in `unloadSnapshot`. A page with no view or no size keeps nothing.
    public func captureUnloadSnapshot() async {
        guard let webView = primaryWebView, webView.bounds.width > 0, webView.bounds.height > 0 else { return }
        let config = WKSnapshotConfiguration()
        // snapshotWidth is in points and comes back at the backing scale, so half the width is 1x.
        config.snapshotWidth = NSNumber(value: Double(webView.bounds.width / 2))
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        unloadSnapshot = data as Data
    }
}
#endif
