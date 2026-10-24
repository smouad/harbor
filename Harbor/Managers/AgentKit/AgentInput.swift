// Licensed under GPL-3.0. See LICENSE.
//
//  AgentInput.swift
//  Harbor
//
//  Native input for agent pages. Events go straight to the web view, not through the window or
//  the system event stream, so they never move the person's pointer, never reach another app and
//  never make the hidden agent page first responder. WebKit handles them as it handles a person's:
//  the page sees trusted events with user activation (popups, clipboard, file pickers work).
//

import AppKit
import Foundation
import WebKit
import HarborWeb

@MainActor
enum AgentInput {
    /// The page's viewport, as the runtime reports it, for turning CSS pixels into view points.
    struct Viewport {
        let width: Double
        let height: Double

        init(_ object: Any?) {
            let dict = object as? [String: Any] ?? [:]
            width = (dict["w"] as? NSNumber)?.doubleValue ?? 0
            height = (dict["h"] as? NSNumber)?.doubleValue ?? 0
        }
    }

    enum InputError: LocalizedError {
        case notInWindow
        case unknownKey(String)
        case threw(String)

        var errorDescription: String? {
            switch self {
            case .notInWindow: "The page is not in a window, so it cannot take native input"
            case .unknownKey(let key): "Unknown key \(key)"
            case .threw(let reason): "Native input failed (\(reason)). Pass input: \"dom\" to use synthetic events."
            }
        }
    }

    // MARK: - Mouse

    static func click(_ webView: WKWebView, x: Double, y: Double, viewport: Viewport, clickCount: Int = 1) throws {
        let location = try windowPoint(webView, x: x, y: y, viewport: viewport)
        try move(webView, to: location)
        for count in 1...max(1, clickCount) {
            try send(webView, type: .leftMouseDown, at: location, clickCount: count)
            try send(webView, type: .leftMouseUp, at: location, clickCount: count)
        }
    }

    static func hover(_ webView: WKWebView, x: Double, y: Double, viewport: Viewport) throws {
        try move(webView, to: try windowPoint(webView, x: x, y: y, viewport: viewport))
    }

    /// A pointer path from `from` to `to` with eased, slightly jittered steps, for `human` moves.
    static func path(from: CGPoint, to: CGPoint, steps: Int) -> [CGPoint] {
        let count = max(2, steps)
        let bend = CGPoint(x: (to.y - from.y) * 0.08, y: (from.x - to.x) * 0.08)
        return (1...count).map { i in
            let t = Double(i) / Double(count)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let arc = sin(t * .pi)
            return CGPoint(x: from.x + (to.x - from.x) * eased + bend.x * arc + Double.random(in: -0.6...0.6),
                           y: from.y + (to.y - from.y) * eased + bend.y * arc + Double.random(in: -0.6...0.6))
        }
    }

    static func moveAlong(_ webView: WKWebView, from: CGPoint, to: CGPoint, viewport: Viewport, steps: Int) async throws {
        for point in path(from: from, to: to, steps: steps) {
            try move(webView, to: try windowPoint(webView, x: point.x, y: point.y, viewport: viewport))
            try await Task.sleep(for: .milliseconds(Int.random(in: 8...20)))
        }
    }

    /// Scrolls the page under (x, y) by `deltaY` CSS pixels with a wheel event, as a trackpad would.
    static func scroll(_ webView: WKWebView, x: Double, y: Double, deltaY: Double, viewport: Viewport) throws {
        let location = try windowPoint(webView, x: x, y: y, viewport: viewport)
        guard let window = webView.window else { throw InputError.notInWindow }
        let screen = window.convertPoint(toScreen: location)
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: Int32(-deltaY.rounded()), wheel2: 0, wheel3: 0) else { return }
        // CGEvent locations are top-left based in global display space.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        guard let event = NSEvent(cgEvent: cg) else { return }
        try deliver { webView.scrollWheel(with: event) }
    }

    /// Until WebKit has handed every mouse event sent so far to the page. It queues each event
    /// until the page acknowledges the one before, so a script run right after a click could run
    /// before the press: a checkbox read as unchanged, a second click toggled it back.
    static func afterPendingMouseEvents(_ webView: WKWebView) async {
        let selector = NSSelectorFromString("_doAfterProcessingAllPendingMouseEvents:")
        guard webView.responds(to: selector) else { return }
        typealias After = @convention(c) (AnyObject, Selector, @convention(block) () -> Void) -> Void
        let after = unsafeBitCast(webView.method(for: selector), to: After.self)
        final class Once {
            var continuation: CheckedContinuation<Void, Never>?
            func resume() {
                continuation?.resume()
                continuation = nil
            }
        }
        _ = await AgentDeadline.run(2) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let once = Once()
                once.continuation = continuation
                // Made outside the guarded call: WebKit keeps this block, and a block made inside
                // that non-escaping closure would carry its context out with it.
                let done: @convention(block) () -> Void = { once.resume() }
                if HarborCatchObjCException({ after(webView, selector, done) }) != nil { once.resume() }
            }
        }
    }

    // MARK: - Keyboard

    /// Presses a key such as "Enter", "Tab", "ArrowDown", "a", or a chord such as "Meta+a",
    /// "Shift+Tab". The focused element of the page receives it.
    static func press(_ webView: WKWebView, _ combo: String) throws {
        let parts = combo.split(separator: "+").map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { throw InputError.unknownKey(combo) }
        var flags: NSEvent.ModifierFlags = []
        for modifier in parts.dropLast() {
            switch modifier.lowercased() {
            case "meta", "cmd", "command": flags.insert(.command)
            case "control", "ctrl": flags.insert(.control)
            case "alt", "option": flags.insert(.option)
            case "shift": flags.insert(.shift)
            default: throw InputError.unknownKey(combo)
            }
        }
        guard let key = Key(keyName) else { throw InputError.unknownKey(combo) }
        let characters = flags.contains(.shift) ? key.characters.uppercased() : key.characters
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: webView.window?.windowNumber ?? 0, context: nil, characters: characters,
                charactersIgnoringModifiers: key.characters, isARepeat: false, keyCode: key.code)
            else { continue }
            try deliver { type == .keyDown ? webView.keyDown(with: event) : webView.keyUp(with: event) }
        }
    }

    struct Key {
        let code: UInt16
        let characters: String

        private static let named: [String: (UInt16, String)] = [
            "enter": (36, "\r"), "return": (36, "\r"), "tab": (48, "\t"), "escape": (53, "\u{1b}"),
            "esc": (53, "\u{1b}"), "space": (49, " "), " ": (49, " "),
            "backspace": (51, "\u{7f}"), "delete": (117, "\u{f728}"),
            "arrowup": (126, "\u{f700}"), "arrowdown": (125, "\u{f701}"),
            "arrowleft": (123, "\u{f702}"), "arrowright": (124, "\u{f703}"),
            "home": (115, "\u{f729}"), "end": (119, "\u{f72b}"),
            "pageup": (116, "\u{f72c}"), "pagedown": (121, "\u{f72d}")
        ]

        /// ANSI key codes for letters and digits, so shortcuts reach the page with the right code.
        private static let letters: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
            "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, "n": 45, "m": 46
        ]

        init?(_ name: String) {
            if let (code, chars) = Self.named[name.lowercased()] {
                self.code = code
                characters = chars
            } else if name.count == 1, let char = name.lowercased().first {
                code = Self.letters[char] ?? 0
                characters = name.lowercased()
            } else {
                return nil
            }
        }
    }

    // MARK: - Plumbing

    /// CSS pixels in the page's viewport to a point in the web view's window. The ratio between
    /// the view's width and the viewport's covers page zoom, so no zoom factor is needed here.
    static func windowPoint(_ webView: WKWebView, x: Double, y: Double, viewport: Viewport) throws -> NSPoint {
        guard webView.window != nil else { throw InputError.notInWindow }
        let bounds = webView.bounds
        let scaleX = viewport.width > 0 ? bounds.width / viewport.width : 1
        let scaleY = viewport.height > 0 ? bounds.height / viewport.height : scaleX
        let inView = NSPoint(x: x * scaleX, y: webView.isFlipped ? y * scaleY : bounds.height - y * scaleY)
        return webView.convert(inView, to: nil)
    }

    /// WKWebView does not implement `mouseMoved:`; it follows the pointer through its own tracking
    /// observer, which a direct call never reaches. `_simulateMouseEnter:` and `_simulateMouseMove:`
    /// feed that same path (WebViewImpl), so hover state, `:hover` and mouseover work. Each takes
    /// the event type a tracking area would send: an enter given a move event throws.
    private static func move(_ webView: WKWebView, to location: NSPoint) throws {
        guard let window = webView.window else { throw InputError.notInWindow }
        let time = ProcessInfo.processInfo.systemUptime
        let enter = NSEvent.enterExitEvent(
            with: .mouseEntered, location: location, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)
        let moved = mouseEvent(window, type: .mouseMoved, at: location, clickCount: 0)
        for (name, event) in [("_simulateMouseEnter:", enter), ("_simulateMouseMove:", moved)] {
            let selector = NSSelectorFromString(name)
            guard let event, webView.responds(to: selector) else { continue }
            typealias Simulate = @convention(c) (AnyObject, Selector, NSEvent) -> Void
            let simulate = unsafeBitCast(webView.method(for: selector), to: Simulate.self)
            try deliver { simulate(webView, selector, event) }
        }
    }

    private static func send(_ webView: WKWebView, type: NSEvent.EventType, at location: NSPoint, clickCount: Int) throws {
        guard let window = webView.window, let event = mouseEvent(window, type: type, at: location, clickCount: clickCount) else {
            throw InputError.notInWindow
        }
        try deliver { type == .leftMouseDown ? webView.mouseDown(with: event) : webView.mouseUp(with: event) }
    }

    private static func mouseEvent(_ window: NSWindow, type: NSEvent.EventType, at location: NSPoint, clickCount: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseDown ? 1 : 0)
    }

    /// Runs an event dispatch with Objective-C exceptions caught (HarborObjCCatch.h): one that
    /// reached Swift would leave the main actor dead, and Browser Control with it.
    private static func deliver(_ dispatch: () -> Void) throws {
        if let failure = HarborCatchObjCException(dispatch) {
            AgentHub.log.error("Native input threw: \(failure, privacy: .public)")
            throw InputError.threw(failure)
        }
    }
}
