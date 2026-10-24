// Licensed under GPL-3.0. See LICENSE.
//
//  AgentPerception.swift
//  Harbor
//
//  Ways for the agent to see a page beyond its DOM: a screenshot of the visible page or the whole
//  page, the same screenshot with each control boxed and labeled with its ref (so a vision model
//  and `observe` point at the same elements), and text read off the pixels with Vision for what
//  the DOM does not hold (canvas, images, PDFs).
//

import AppKit
import Foundation
import Vision
import WebKit

@MainActor
enum AgentPerception {
    /// Tallest full-page capture, in points; longer pages are cut here.
    static let fullPageLimit: CGFloat = 16_000

    // MARK: - Capture

    static func visible(_ webView: WKWebView, maxWidth: CGFloat) async throws -> NSImage {
        let config = WKSnapshotConfiguration()
        let scale = webView.window?.backingScaleFactor ?? 2
        config.snapshotWidth = NSNumber(value: Double(min(webView.bounds.width, maxWidth / scale)))
        return try await webView.takeSnapshot(configuration: config)
    }

    /// The whole page, rendered through WebKit's PDF path (which draws the full document, not
    /// just what is on screen) and rasterized.
    static func fullPage(_ webView: WKWebView, maxWidth: CGFloat) async throws -> NSImage {
        let data = try await webView.pdf(configuration: WKPDFConfiguration())
        guard let rep = NSPDFImageRep(data: data) else { throw AgentError.invalid("The page could not be captured") }
        let page = rep.bounds
        let scale = min(1, maxWidth / max(page.width, 1))
        let height = min(page.height, fullPageLimit)
        let size = NSSize(width: page.width * scale, height: height * scale)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            // Keep the top of the page when it is cut: PDF space starts at the bottom.
            let offset = (page.height - height) * scale
            rep.draw(in: NSRect(x: 0, y: -offset, width: page.width * scale, height: page.height * scale))
            return true
        }
        return image
    }

    // MARK: - Marks

    /// `image` (the visible page) with each element boxed and its ref written beside it.
    static func marked(_ image: NSImage, elements: [[String: Any]], viewportWidth: Double) -> NSImage {
        let scale = viewportWidth > 0 ? image.size.width / viewportWidth : 1
        let colors: [NSColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemPink, .systemTeal]
        return NSImage(size: image.size, flipped: true) { rect in
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            for (i, element) in elements.enumerated() {
                guard let ref = element["ref"] as? String else { continue }
                let number = { (key: String) in CGFloat((element[key] as? NSNumber)?.doubleValue ?? 0) * scale }
                let box = NSRect(x: number("x"), y: number("y"), width: number("w"), height: number("h"))
                let color = colors[i % colors.count]
                color.withAlphaComponent(0.9).setStroke()
                let path = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
                path.lineWidth = 1.5
                path.stroke()
                let label = NSAttributedString(string: ref, attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.white
                ])
                let size = label.size()
                let tag = NSRect(x: box.minX, y: max(0, box.minY - size.height - 2), width: size.width + 6, height: size.height + 2)
                color.setFill()
                tag.fill()
                label.draw(at: NSPoint(x: tag.minX + 3, y: tag.minY + 1))
            }
            return true
        }
    }

    // MARK: - OCR

    struct Line {
        let text: String
        let confidence: Float
        /// In the image's points, top-left origin.
        let box: CGRect
    }

    static func recognizeText(in image: NSImage) async throws -> [Line] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw AgentError.invalid("The capture has no pixels")
        }
        let size = image.size
        return try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: cg).perform([request])
            return (request.results ?? []).compactMap { observation -> Line? in
                guard let best = observation.topCandidates(1).first else { return nil }
                let b = observation.boundingBox
                let box = CGRect(x: b.minX * size.width, y: (1 - b.maxY) * size.height, width: b.width * size.width, height: b.height * size.height)
                return Line(text: best.string, confidence: best.confidence, box: box)
            }
        }.value
    }
}
