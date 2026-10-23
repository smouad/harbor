// Licensed under GPL-3.0. See LICENSE.
//
//  UnloadSnapshotView.swift
//  Harbor
//
//  A page's last snapshot laid over its reloading view, so going back to an unloaded tab reads
//  as instant. Clicks pass through to the page underneath.
//

import AppKit
import HarborDesign
import ImageIO

final class UnloadSnapshotView: NSView {
    /// Never shown longer than this, whatever the page does.
    private static let maxDuration: TimeInterval = 4

    init?(jpeg: Data, frame: NSRect) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        autoresizingMask = [.width, .height]
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.maxDuration) { [weak self] in self?.fadeOut() }
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func fadeOut() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HarborDesign.Motion.standardDuration
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.removeFromSuperview()
        }
    }
}
