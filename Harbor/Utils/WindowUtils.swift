// Licensed under GPL-3.0. See LICENSE.
import AppKit
import Foundation
//
//  WindowUtils.swift
//  Harbor
//
//  Created by Maciek Bagiński on 31/07/2025.
//
import SwiftUI

extension View {
    public func backgroundDraggable() -> some View {
        overlay(WindowDragArea())
    }

    public func backgroundDraggable<G: Gesture>(gesture: G) -> some View {
        modifier(BackgroundDraggableModifier(gesture: gesture))
    }

    public func conditionalWindowDrag() -> some View {
        overlay(WindowDragArea())
    }
}

private struct BackgroundDraggableModifier<G: Gesture>: ViewModifier {
    let gesture: G

    func body(content: Content) -> some View {
        content
            .gesture(
                gesture
            )
    }
}

extension NSWindow {
    /// Does what double-clicking a title bar does, as chosen in System Settings > Desktop & Dock >
    /// "Double-click a window's title bar to". Harbor's chrome covers the real title bar, so its
    /// draggable areas call this themselves. Fill, the default, and Zoom both zoom here: Harbor
    /// names no standard frame, so a zoom fills the screen and the next one restores the window.
    func performTitleBarDoubleClick() {
        let defaults = UserDefaults.standard
        switch defaults.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": performMiniaturize(nil)
        case "None": break
        case nil where defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick"): performMiniaturize(nil)
        default: performZoom(nil)
        }
    }
}

/// True for the second press of a double-click, which zooms instead of dragging the window.
@MainActor
private func handledTitleBarDoubleClick() -> Bool {
    guard let event = NSApp.currentEvent, event.type == .leftMouseDown, event.clickCount == 2,
          let window = event.window ?? NSApp.keyWindow else { return false }
    window.performTitleBarDoubleClick()
    return true
}

/// An empty stretch of Harbor's chrome standing in for the title bar it covers: a press drags the
/// window and a double-click does what one on a title bar does. AppKit rather than a SwiftUI
/// gesture: `performDrag` runs its own loop and takes the mouse-up, so a drag gesture never saw
/// the second press of a double-click and the sidebar's double-click did nothing.
private struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowDragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 { return window.performTitleBarDoubleClick() }
        // A tab or favorite drag in progress keeps the window still.
        let locks = DragLockManager.shared
        guard locks.canStartAnyDrag(), locks.startDrag() else { return }
        window.performDrag(with: event)
        locks.forceReleaseAll()
    }
}

struct WindowDragGesture: Gesture {
    var body: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if value.translation == .zero, handledTitleBarDoubleClick() { return }
                // Check global drag lock directly from shared instance
                let dragLockManager = DragLockManager.shared

                if dragLockManager.canStartAnyDrag() {
                    // Generate a session ID for this specific drag attempt
                    let sessionID = UUID().uuidString

                    if dragLockManager.startDrag(ownerID: sessionID) {
                        if let window = NSApp.keyWindow {
                            window.performDrag(with: NSApp.currentEvent!)
                        }
                    }
                }
            }
            .onEnded { value in
                // We can't reliably track session ID in a struct, so force release all locks
                DragLockManager.shared.forceReleaseAll()
            }
    }
}
