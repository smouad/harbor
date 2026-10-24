// Licensed under GPL-3.0. See LICENSE.
import AppKit
import WebKit

/// Where the split drop cards sit. One source for what is drawn, what lights up under the pointer
/// and what a drop lands on, which had been three different sizes.
enum SplitCardMetrics {
    static let width: CGFloat = 237
    static let height: CGFloat = 394
    static let padding: CGFloat = 20
    /// How far past a card's edge a drag still counts as on it: the card leans toward the pointer.
    static let margin: CGFloat = 50

    /// A card's frame in a container of `size`, with the origin at the top left.
    static func frame(of side: SplitViewManager.Side, in size: CGSize) -> CGRect {
        let x = side == .left ? padding : size.width - padding - width
        return CGRect(x: x, y: (size.height - height) / 2, width: width, height: height)
    }
}

final class SplitDropCaptureView: NSView {
    weak var browserManager: BrowserManager?
    weak var splitManager: SplitViewManager?
    var windowId: UUID?
    private var isDragActive: Bool = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // Accept plain text drags (UUID string for a Tab)
        // A tab from the sidebar, or a link dragged out of a page (a URL, or its text).
        registerForDraggedTypes([.harborTabItem, .string, .URL])
        // Transparent to normal mouse events; only DnD uses these callbacks
        isHidden = false
    }

    // Only intercept events during an active drag; otherwise pass through
    override func hitTest(_ point: NSPoint) -> NSView? { 
        // Return nil to pass through all mouse events when not dragging
        // This allows right-clicks to reach the webview below for context menus
        return isDragActive ? self : nil 
    }
    
    // Override acceptsFirstResponder to prevent this view from intercepting events
    override var acceptsFirstResponder: Bool { false }

    // MARK: - Dragging
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Selected text and anything else that is not a tab or a link gets no cards.
        guard acceptsPayload(sender.draggingPasteboard) else { return [] }
        isDragActive = true
        updatePreview(sender)
        updateDragLocation(sender)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard acceptsPayload(sender.draggingPasteboard) else { return [] }
        isDragActive = true
        updateDragLocation(sender)
        updatePreview(sender)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragActive = false
        if let windowId {
            splitManager?.updateDragLocation(nil, for: windowId)
            splitManager?.endPreview(cancel: true, for: windowId)
        }
        // Signal UI to clear any drag-hiding state even on invalid drops
        NotificationCenter.default.post(name: .tabDragDidEnd, object: nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let bm = browserManager, let sm = splitManager, let windowId else { return false }
        let pb = sender.draggingPasteboard
        let tabId = Self.tabID(in: pb)
        let linkURL = tabId == nil ? Self.linkURL(in: pb) : nil
        guard (tabId.flatMap { bm.tabs.item($0) } != nil) || linkURL != nil else {
            // Invalid payload; clear any lingering drag UI state
            sm.updateDragLocation(nil, for: windowId)
            sm.endPreview(cancel: false, for: windowId)
            NotificationCenter.default.post(name: .tabDragDidEnd, object: nil)
            return false
        }

        let side = sideForDragInCard(sender)
        guard let dropSide = side else {
            sm.updateDragLocation(nil, for: windowId)
            sm.endPreview(cancel: false, for: windowId)
            return false
        }
        
        sm.updateDragLocation(nil, for: windowId)
        sm.endPreview(cancel: false, for: windowId)
        
        guard let windowState = bm.windowRegistry?.windows[windowId] else { return false }
        if let linkURL {
            // A link becomes a tab beside the current one, and takes that side of the split.
            if let created = bm.tabs.open(url: linkURL, in: windowState, placement: .background) {
                sm.enterSplit(with: created, placeOn: dropSide, in: windowState)
            }
        } else if let id = tabId {
            // Redundant replace guard
            if sm.isSplit(for: windowId) {
                let leftId = sm.leftTabId(for: windowId)
                let rightId = sm.rightTabId(for: windowId)
                if (dropSide == .left && leftId == id) || (dropSide == .right && rightId == id) {
                    return true
                }
            }
            sm.enterSplit(with: id, placeOn: dropSide, in: windowState)
        }
        // Cancel any in-progress sidebar/tab drag to prevent unintended reorder/removal
        DispatchQueue.main.async {
            HarborDragSessionManager.shared.cancelDrag()
        }
        isDragActive = false
        return true
    }

    // MARK: - Helpers
    private func updatePreview(_ sender: NSDraggingInfo) {
        let side = sideForDragInCard(sender)
        guard let windowId, let sm = splitManager else { return }
        
        let currentState = sm.getSplitState(for: windowId)
        if currentState.isPreviewActive {
            sm.updatePreviewSide(side, for: windowId)
        } else {
            sm.beginPreview(side: side, for: windowId)
        }
    }
    
    private func updateDragLocation(_ sender: NSDraggingInfo) {
        let loc = convert(sender.draggingLocation, from: nil)
        if let windowId {
            splitManager?.updateDragLocation(loc, for: windowId)
        }
    }

    /// Which card the pointer is on, by the same rule the cards use to lean toward it.
    private func sideForDragInCard(_ sender: NSDraggingInfo) -> SplitViewManager.Side? {
        let drag = convert(sender.draggingLocation, from: nil)
        // The cards are placed from the top left.
        let point = CGPoint(x: drag.x, y: isFlipped ? drag.y : bounds.height - drag.y)
        for side in [SplitViewManager.Side.left, .right] {
            let card = SplitCardMetrics.frame(of: side, in: bounds.size)
                .insetBy(dx: -SplitCardMetrics.margin, dy: -SplitCardMetrics.margin)
            if card.contains(point) { return side }
        }
        return nil
    }

    // MARK: - Payloads

    private func acceptsPayload(_ pasteboard: NSPasteboard) -> Bool {
        Self.tabID(in: pasteboard) != nil || Self.linkURL(in: pasteboard) != nil
    }

    private static func tabID(in pasteboard: NSPasteboard) -> UUID? {
        if let item = HarborDragItem.fromPasteboard(pasteboard) { return item.tabId }
        return pasteboard.string(forType: .string).flatMap { UUID(uuidString: $0) }
    }

    /// A web link dragged out of a page: its URL, or text that is one.
    private static func linkURL(in pasteboard: NSPasteboard) -> URL? {
        func web(_ url: URL?) -> URL? {
            guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return nil }
            return url
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], let link = urls.compactMap({ web($0) }).first {
            return link
        }
        return web(pasteboard.string(forType: .string).flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) })
    }
}
