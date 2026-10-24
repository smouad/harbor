// Licensed under GPL-3.0. See LICENSE.
//
//  SidebarPiPPanel.swift
//  Harbor
//
//  Picture-in-picture pinned to the sidebar: when a playing video's tab is left, its live web
//  view moves into the sidebar directly above the media controls bar, and can be dragged out
//  into a floating panel and back. The page is not cloned: one live view changes superview.
//

import AppKit
import ApplicationServices
import SwiftUI
import WebKit
import os
import HarborDesign
import HarborSettings
import HarborUI
import HarborWeb

// MARK: - Staying on screen

/// Moved back inside the screen it mostly sits on, and shrunk if it is bigger than that screen's
/// usable area, so a drag or a gesture can never leave the player half out of sight on a laptop.
private func pipKeptOnScreen(_ frame: CGRect) -> CGRect {
    func overlap(_ screen: NSScreen) -> CGFloat {
        let shared = screen.visibleFrame.intersection(frame)
        return shared.isNull ? 0 : shared.width * shared.height
    }
    guard let screen = NSScreen.screens.max(by: { overlap($0) < overlap($1) }) ?? NSScreen.main else { return frame }
    let area = screen.visibleFrame
    var kept = frame
    if kept.width > area.width || kept.height > area.height {
        let scale = min(area.width / kept.width, area.height / kept.height)
        kept.size = CGSize(width: kept.width * scale, height: kept.height * scale)
    }
    kept.origin.x = min(max(kept.minX, area.minX), area.maxX - kept.width)
    kept.origin.y = min(max(kept.minY, area.minY), area.maxY - kept.height)
    return kept
}

// MARK: - Controller

/// One per window. Owns which page is showing in the sidebar and the page-side isolation that
/// makes the video fill it.
@MainActor
@Observable
final class SidebarPiPController: PictureInPictureHolder {
    private static let logger = Logger(subsystem: "com.mouad.harbor", category: "SidebarPiP")
    /// Every PiP script runs here, out of the page's reach.
    static let world = WKContentWorld.world(name: "HarborPiP")

    private(set) var isFloating = false
    /// While the float panel is being dragged the sidebar shows its drop zone.
    private(set) var isDragging = false
    private(set) var isOverDock = false
    @ObservationIgnored private var floatWindow: NSPanel?
    @ObservationIgnored weak var dockZoneView: NSView?
    /// The float panel's width and place, kept across launches. Height follows the video.
    private static var lastFloatWidth: CGFloat {
        get { UserDefaults.standard.object(forKey: "sidebarPiP.floatWidth") as? CGFloat ?? 420 }
        set { UserDefaults.standard.set(newValue, forKey: "sidebarPiP.floatWidth") }
    }
    private static var lastFloatOrigin: CGPoint? {
        get { UserDefaults.standard.string(forKey: "sidebarPiP.floatOrigin").map(NSPointFromString) }
        set { UserDefaults.standard.set(newValue.map(NSStringFromPoint), forKey: "sidebarPiP.floatOrigin") }
    }
    /// Bumped on every enter and exit, so a late script reply for an earlier video is dropped.
    @ObservationIgnored private var generation = 0
    /// Only the newest `next()` wait may act.
    @ObservationIgnored private var followToken = 0

    @ObservationIgnored private weak var windowState: BrowserWindowState?

    private(set) var itemID: UUID?
    private(set) var webView: WKWebView?
    private(set) var session: PageSession?
    /// False until the isolated video has been presented, so no frame from before is ever shown.
    private(set) var isReady = false

    /// Where the video is painted, in view points relative to the web view. The host crops and
    /// scales to exactly this rect.
    private(set) var videoRect: CGRect = .zero

    /// The page the sidebar media surface is about, kept after minimising so the bar describes
    /// the same video the panel was showing. The bar cannot re-derive this on its own: it finds
    /// a tab by "is playing", which skips a paused video and leaves the previous one on screen.
    private(set) var barSession: PageSession?

    /// Whether a video leaving its tab docks above the sidebar's media controls. Off by default:
    /// it floats over the page instead, and can still be dragged into the dock.
    static var dockInSidebar: Bool { UserDefaults.standard.bool(forKey: HarborSettingsService.pipDockInSidebarKey) }

    var isShowing: Bool { itemID != nil }
    var isDocked: Bool { isShowing && !isFloating }
    var pictureInPictureItemID: UUID? { itemID }
    var aspect: CGFloat { videoRect.height > 1 ? max(videoRect.width / videoRect.height, 0.1) : 16 / 9 }

    init(windowState: BrowserWindowState) {
        self.windowState = windowState
    }

    /// Feeds play whatever scrolls past. Facebook serves long videos under /reel/ too, so its
    /// reels are told apart by the page script's portrait check.
    static func allowsAutomatic(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return true }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("instagram.com") || on("tiktok.com") { return false }
        return !(on("youtube.com") && url.path.lowercased().hasPrefix("/shorts"))
    }

    // MARK: - Enter

    /// Moves the live view into the sidebar and isolates its video; `automatic` refuses paused,
    /// muted, looping or portrait video. `onFailure` lets the caller fall back to system PiP.
    func enter(session: PageSession, webView: WKWebView, automatic: Bool, onFailure: @escaping () -> Void) {
        // Only Harbor's own view class stops the pointer and restores the page on the way back.
        guard webView is FocusableWKWebView else { return onFailure() }
        exit()
        generation += 1
        // Published before the compositor's pass, so the view moves between containers in one
        // update and the page never goes hidden. The slot stays clear until the video is ready.
        withAnimation(HarborDesign.Motion.spring) {
            self.session = session
            barSession = session
            self.webView = webView
            itemID = session.itemID
        }
        if webView.window?.firstResponder === webView { webView.window?.makeFirstResponder(nil) }
        isolate(webView, automatic: automatic, onFailure: onFailure)
        followNavigation(of: session, generation: generation)
    }

    private func isolate(_ webView: WKWebView, automatic: Bool, onFailure: @escaping () -> Void) {
        let generation = generation
        // Before the script, so a reply dropped by a quick return still leaves a restore behind.
        (webView as? FocusableWKWebView)?.isPictureInPictureIsolated = true
        webView.callAsyncJavaScript(
            Self.pageScript + "return __harborPiP.isolate(zoom, automatic);",
            arguments: ["zoom": Double(webView.pageZoom), "automatic": automatic],
            in: nil, in: Self.world
        ) { [weak self] result in
            guard let self, self.generation == generation, self.webView === webView else { return }
            let info = (try? result.get()) as? [String: Any]
            guard let rect = Self.rect(from: info) else {
                Self.logger.notice("no video to isolate: \(String(describing: info), privacy: .public)")
                self.exit()
                if info?["skip"] as? Bool != true { onFailure() }
                return
            }
            self.setCrop(rect)
            guard !self.isReady else { return self.follow(webView) }
            Self.afterNextPresentation(of: webView) { [weak self] in
                guard let self, self.generation == generation else { return }
                withAnimation(HarborDesign.Motion.spring) { self.isReady = true }
                self.follow(webView)
                if !Self.dockInSidebar { self.popOut(fromDock: false) }
            }
        }
    }

    /// Keeps the crop on the video as the page changes: the next video, an ad, a resize.
    private func follow(_ webView: WKWebView) {
        followToken += 1
        let token = followToken, generation = generation
        webView.callAsyncJavaScript("return await __harborPiP.next();", arguments: [:], in: nil, in: Self.world) {
            [weak self] result in
            guard let self, self.generation == generation, self.followToken == token, self.webView === webView
            else { return }
            let info = (try? result.get()) as? [String: Any]
            if let rect = Self.rect(from: info) {
                self.setCrop(rect)
                self.follow(webView)
            } else if info?["ended"] as? Bool != true {
                // The document changed or the video left it: pick again, or end.
                self.refresh()
            }
        }
    }

    /// A navigation, even a single-page one to the next video, can replace the player.
    private func followNavigation(of session: PageSession, generation: Int) {
        withObservationTracking { _ = session.url } onChange: { [weak self, weak session] in
            DispatchQueue.main.async {
                guard let self, let session, self.generation == generation else { return }
                self.refresh()
                self.followNavigation(of: session, generation: generation)
            }
        }
    }

    private func refresh() {
        guard let webView else { return }
        isolate(webView, automatic: false) {}
    }

    private func setCrop(_ rect: CGRect) {
        guard rect != videoRect else { return }
        videoRect = rect
        guard let floatWindow, let root = floatWindow.contentView as? FloatRootView else { return }
        root.container.crop = rect
        floatWindow.contentAspectRatio = rect.size
        var frame = floatWindow.frame
        frame.size.height = frame.width / aspect
        floatWindow.setFrame(frame, display: true)
    }

    private static func rect(from info: [String: Any]?) -> CGRect? {
        guard let info, info["ok"] as? Bool == true,
            let x = info["x"] as? Double, let y = info["y"] as? Double,
            let width = info["w"] as? Double, let height = info["h"] as? Double,
            width > 1, height > 1
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Runs `body` once WebKit has put the page's latest frame on screen, or after a short wait
    /// for a page that is not presenting (an occluded window).
    private static func afterNextPresentation(of webView: WKWebView, _ body: @escaping () -> Void) {
        var done = false
        let once = { if !done { done = true; body() } }
        let selector = NSSelectorFromString("_doAfterNextPresentationUpdate:")
        if webView.responds(to: selector) {
            typealias Call = @convention(c) (AnyObject, Selector, @escaping @convention(block) () -> Void) -> Void
            unsafeBitCast(webView.method(for: selector), to: Call.self)(webView, selector) { once() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { once() }
    }

    // MARK: - Exit

    /// The page is restored when its view next lands outside a crop, in its tab or a split pane;
    /// minimising leaves it isolated off screen until then.
    func exit() {
        guard itemID != nil else { return }
        closeFloat()
        clear()
    }

    private func clear() {
        generation += 1
        isFloating = false
        isReady = false
        itemID = nil
        webView = nil
        session = nil
        videoRect = .zero
    }

    /// Exits when the sidebar is showing `itemID`, and in either case stops the bar describing
    /// that page: reaching the tab again, or closing it, ends the sidebar's claim on it.
    func exitIfShowing(_ itemID: UUID) {
        if barSession?.itemID == itemID { barSession = nil }
        guard self.itemID == itemID else { return }
        exit()
    }

    /// Brings this window forward on the video's tab; selecting the tab plays the video inline again.
    func returnToTab() {
        guard let session, let windowState, let tabs = session.controller else { return }
        windowState.window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
        tabs.select(session.itemID, in: windowState)
    }

    // MARK: - Floating

    /// Called mid-drag from the sidebar: the panel appears under the pointer and keeps following.
    /// `fromDock` is false when the video was never docked (it floats on arrival), so the panel
    /// opens in place instead of growing out of a dock box that is still collapsed.
    func popOut(fromDock: Bool = true) {
        guard let webView, isReady, !isFloating else { return }
        let size = CGSize(width: Self.lastFloatWidth, height: Self.lastFloatWidth / aspect)
        let mouse = NSEvent.mouseLocation
        let dragging = fromDock && NSEvent.pressedMouseButtons & 1 == 1
        var free = CGRect(origin: CGPoint(x: mouse.x - size.width / 2, y: mouse.y - size.height / 2), size: size)
        if !fromDock, let window = windowState?.window {
            // First time: the window's top right corner, clear of the toolbar.
            let inset = HarborDesign.Spacing.xl
            free.origin = CGPoint(x: window.frame.maxX - size.width - inset,
                                  y: window.frame.maxY - size.height - HarborDesign.Size.row * 2 - inset)
        }
        // Back where it last floated, unless that screen is gone.
        if let origin = Self.lastFloatOrigin {
            let last = CGRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(last) }) { free = last }
        }
        free = pipKeptOnScreen(free)
        // Opens over the docked video: a drag starts snapped into the dock box it is leaving.
        let docked = !fromDock ? free : webView.superview.flatMap { view in
            view.window.map { $0.convertToScreen(view.convert(view.bounds, to: nil)) }
        } ?? free
        let panel = SidebarPiPFloatPanel(contentRect: docked)
        let root = FloatRootView(controller: self, frame: CGRect(origin: .zero, size: docked.size))
        root.container.crop = videoRect
        panel.contentView = root
        // With the web view as first responder, YouTube's search box took focus within a second
        // of every pop-out and dropped its history over the video.
        panel.initialFirstResponder = root

        // Set before the move: the docked host must see it and leave the view alone.
        isFloating = true
        isDragging = dragging
        isOverDock = dragging
        webView.autoresizingMask = []
        root.container.addSubview(webView)
        panel.orderFrontRegardless()
        floatWindow = panel
        if dragging {
            DispatchQueue.main.async { self.trackDrag(freeSize: size) }
        } else if fromDock {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HarborDesign.Motion.standardDuration
                panel.animator().setFrame(free, display: true)
            }
        }
    }

    /// Back into the sidebar: the docked host adopts the view once it is orphaned. A hidden
    /// sidebar has no host, so the video stays afloat.
    /// `remember` is false when the panel sits snapped in the dock box, which is not its place.
    func dock(remember: Bool = true) {
        guard isFloating, windowState?.isSidebarVisible == true else { return }
        closeFloat(remember: remember)
        isFloating = false
    }

    /// Called when the panel comes to rest: after a drag, a resize, or as it closes.
    func rememberFloat() {
        guard let floatWindow, !isOverDock else { return }
        let kept = pipKeptOnScreen(floatWindow.frame)
        Self.lastFloatWidth = kept.width
        Self.lastFloatOrigin = kept.origin
    }

    /// Slides the panel back into view when a drag, a resize or a change of displays left part
    /// of it off screen. It may be dragged out freely; it comes back when let go.
    func settleOnScreen() {
        guard let floatWindow, !isOverDock else { return }
        let kept = pipKeptOnScreen(floatWindow.frame)
        guard kept != floatWindow.frame else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = HarborDesign.Motion.standardDuration
            floatWindow.animator().setFrame(kept, display: true)
        } completionHandler: { [weak self] in
            self?.rememberFloat()
        }
    }

    private func closeFloat(remember: Bool = true) {
        guard let floatWindow else { return }
        if remember { rememberFloat() }
        webView?.removeFromSuperview()
        floatWindow.close()
        self.floatWindow = nil
    }

    /// Moves the panel with the mouse until release, docking when released over the drop zone.
    /// `freeSize` is the panel's size outside the dock box, when it starts snapped inside it.
    func trackDrag(freeSize: CGSize? = nil) {
        guard let window = floatWindow else { return }
        guard NSEvent.pressedMouseButtons & 1 == 1 else {
            // Let go before tracking began, still in the box: nothing left the sidebar.
            if isOverDock {
                isDragging = false
                isOverDock = false
                dock(remember: false)
            }
            return
        }
        let start = NSEvent.mouseLocation
        let size = freeSize ?? window.frame.size
        // As a share of the panel, so one snapped small grows back around the same spot.
        let grab = CGPoint(x: (start.x - window.frame.minX) / window.frame.width,
                           y: (start.y - window.frame.minY) / window.frame.height)
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration,
                           mode: .eventTracking) { [weak self] event, stop in
            guard let self, let event, event.type == .leftMouseDragged else {
                stop.pointee = true
                guard let self else { return }
                let shouldDock = self.isOverDock
                self.isDragging = false
                self.isOverDock = false
                if shouldDock {
                    self.dock(remember: false)
                    // A resize before the drag still counts; the snapped size does not.
                    Self.lastFloatWidth = size.width
                } else {
                    self.settleOnScreen()
                    self.rememberFloat()
                    (window.contentView as? FloatRootView)?.syncHover()
                }
                return
            }
            let mouse = NSEvent.mouseLocation
            if !self.isDragging { self.isDragging = true }
            let zone = self.dockZone
            // The box is drawn a frame after the drag starts; until then the panel stays put.
            let over = zone.map { $0.contains(mouse) } ?? self.isOverDock
            let free = CGRect(origin: CGPoint(x: mouse.x - grab.x * size.width, y: mouse.y - grab.y * size.height),
                              size: size)
            if over != self.isOverDock {
                self.isOverDock = over
                // Shrinks into the box on the way in, grows back under the pointer on the way out.
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = HarborDesign.Motion.standardDuration
                    window.animator().setFrame(over ? zone ?? free : free, display: true)
                }
            } else if !over {
                window.setFrameOrigin(free.origin)
            }
        }
    }

    private var dockZone: CGRect? {
        guard let view = dockZoneView, let window = view.window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Takes over another window's video, docked or floating, when this window gains focus.
    func adopt(from other: SidebarPiPController) {
        videoRect = other.videoRect
        session = other.session
        barSession = other.barSession
        webView = other.webView
        floatWindow = other.floatWindow
        (floatWindow?.contentView as? FloatRootView)?.controller = self
        isFloating = other.isFloating
        itemID = other.itemID
        let ready = other.isReady
        other.floatWindow = nil
        other.barSession = nil
        other.clear()
        generation += 1
        isReady = ready
        if ready, let webView { follow(webView) }
        if let session { followNavigation(of: session, generation: generation) }
    }

    func togglePlay() {
        webView?.evaluateJavaScript(
            "(() => { const v = window.__harborPiP?.video(); if (v) v.paused ? v.play() : v.pause(); })();",
            in: nil, in: Self.world)
    }

    func seek(_ seconds: Int) {
        webView?.evaluateJavaScript(
            "(() => { const v = window.__harborPiP?.video(); if (v) v.currentTime = Math.max(0, Math.min(v.duration || Infinity, v.currentTime + (\(seconds)))); })();",
            in: nil, in: Self.world)
    }

    /// Position and length in seconds; nil for a live stream, which has no length.
    func playback(_ reply: @escaping ((time: Double, duration: Double)?) -> Void) {
        webView?.evaluateJavaScript(
            "(() => { const v = window.__harborPiP?.video(); return v && isFinite(v.duration) && v.duration > 0 ? [v.currentTime, v.duration] : null; })();",
            in: nil, in: Self.world
        ) { result in
            let pair = (try? result.get()) as? [Double]
            reply(pair?.count == 2 ? (pair![0], pair![1]) : nil)
        }
    }

    func scrub(to seconds: Double) {
        webView?.evaluateJavaScript(
            "(() => { const v = window.__harborPiP?.video(); if (v) v.currentTime = \(seconds); })();",
            in: nil, in: Self.world)
    }

    /// Undoes `pageScript` in a page whose view has left the crop.
    static func restorePage(in webView: WKWebView) {
        webView.evaluateJavaScript("window.__harborPiP?.restore(true);", in: nil, in: world)
    }

    // MARK: - Page script

    /// Picks the video a person is watching: in system PiP, then playing, audible, largest.
    /// Shared with `PiPManager`, which runs it in the page's world.
    static let pickerScript = """
    const harborPlaying = v => !v.paused && !v.ended && v.readyState >= 2;
    // Feed autoplay, shorts and reels: nobody chose to watch these.
    const harborRefusesAutomatic = v => !harborPlaying(v) || v.muted || v.volume === 0 || v.loop
        || v.videoHeight > v.videoWidth;
    function harborPickVideo() {
        const playing = harborPlaying;
        const area = v => { const r = v.getBoundingClientRect(); return r.width * r.height; };
        const found = [...document.querySelectorAll('video')];
        if (!found.some(playing)) {
            // Some players keep the video in an open shadow root.
            const roots = [document];
            while (roots.length) {
                for (const el of roots.pop().querySelectorAll('*')) {
                    if (!el.shadowRoot) continue;
                    roots.push(el.shadowRoot);
                    found.push(...el.shadowRoot.querySelectorAll('video'));
                }
            }
        }
        const score = v => (v.webkitPresentationMode === 'picture-in-picture' ? 8 : 0)
            + (playing(v) ? 4 : 0) + (!v.muted && v.volume > 0 ? 2 : 0);
        return found.filter(v => area(v) > 1 || v.webkitPresentationMode === 'picture-in-picture')
            .sort((a, b) => score(b) - score(a) || area(b) - area(a))[0] || null;
    }
    """

    /// Defines `__harborPiP`: hides the rest of the player and anything over the video, in place.
    /// Visibility is used because a descendant can override it and stacking contexts cannot.
    static let pageScript = """
    if (!window.__harborPiP) window.__harborPiP = (() => {
        \(pickerScript)
        const S = { styles: [], covers: [] };
        const css = '[data-harbor-pip-root] *, [data-harbor-pip-root]::before, [data-harbor-pip-root]::after, '
            + '[data-harbor-pip-cover] { visibility: hidden !important; } '
            + '[data-harbor-pip-video] { visibility: visible !important; }';
        const parentOf = n => n.parentElement || (n.parentNode && n.parentNode.host) || null;

        // The video's painted frame in CSS pixels, which letterboxing makes smaller than its box.
        function painted(v) {
            const cs = getComputedStyle(v), r = v.getBoundingClientRect();
            const px = k => parseFloat(cs[k]) || 0;
            let x = r.x + px('borderLeftWidth') + px('paddingLeft');
            let y = r.y + px('borderTopWidth') + px('paddingTop');
            let w = r.width - px('borderLeftWidth') - px('borderRightWidth') - px('paddingLeft') - px('paddingRight');
            let h = r.height - px('borderTopWidth') - px('borderBottomWidth') - px('paddingTop') - px('paddingBottom');
            const vw = v.videoWidth, vh = v.videoHeight;
            const s = { contain: Math.min(w / vw, h / vh), 'scale-down': Math.min(1, w / vw, h / vh), none: 1 }[cs.objectFit];
            if (vw > 0 && vh > 0 && s) {
                const [ox, oy] = (cs.objectPosition || '').split(' ');
                const offset = (t, free) => t && t.endsWith('%') ? free * parseFloat(t) / 100
                    : t && t.endsWith('px') ? parseFloat(t) : free / 2;
                x += offset(ox, w - vw * s);
                y += offset(oy, h - vh * s);
                w = vw * s;
                h = vh * s;
            }
            return { x, y, w, h };
        }

        // Only what is inside the viewport is drawn.
        function clip(p) {
            const x = Math.max(p.x, 0), y = Math.max(p.y, 0);
            return { x, y, w: Math.min(p.x + p.w, innerWidth) - x, h: Math.min(p.y + p.h, innerHeight) - y };
        }

        function rect() {
            if (!S.video || !S.video.isConnected) return { ok: false };
            const p = clip(painted(S.video)), vv = visualViewport, k = S.zoom * (vv ? vv.scale : 1);
            const ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
            return { ok: true, x: (p.x - ox) * k, y: (p.y - oy) * k, w: p.w * k, h: p.h * k };
        }

        // Scrolls only when the video is mostly out of view, and remembers where the page was.
        function bringIntoView(v) {
            const p = painted(v), c = clip(p);
            if (Math.max(0, c.w) * Math.max(0, c.h) >= 0.9 * p.w * p.h) return;
            // Every scroller the scroll may move, not only the window.
            if (!S.scroll) {
                S.scroll = { url: location.href, at: [] };
                for (let n = parentOf(v); n; n = parentOf(n)) S.scroll.at.push([n, n.scrollLeft, n.scrollTop]);
            }
            v.scrollIntoView({ block: 'center', inline: 'nearest', behavior: 'instant' });
        }

        // The highest ancestor that is still about the video's size: the player.
        function playerRoot(v) {
            const box = v.getBoundingClientRect();
            let root = v;
            for (let n = parentOf(v); n && n !== document.body && n !== document.documentElement; n = parentOf(n)) {
                const r = n.getBoundingClientRect();
                if (r.width > box.width * 1.25 + 8 || r.height > box.height * 1.5 + 8) break;
                root = n;
            }
            return root;
        }

        // Anything outside the player painted over the video: a sticky header, a banner.
        function markCovers() {
            const p = clip(painted(S.video)), stop = new Set();
            for (let n = S.root; n; n = parentOf(n)) stop.add(n);
            for (const fx of [0.02, 0.5, 0.98]) for (const fy of [0.02, 0.5, 0.98]) {
                for (const el of document.elementsFromPoint(p.x + p.w * fx, p.y + p.h * fy)) {
                    if (stop.has(el) || S.root.contains(el)) break;
                    if (el.hasAttribute('data-harbor-pip-cover')) continue;
                    el.setAttribute('data-harbor-pip-cover', '');
                    S.covers.push(el);
                }
            }
        }

        function isolate(zoom, automatic) {
            restore(false);
            const v = harborPickVideo();
            if (!v) return { ok: false };
            if (automatic && harborRefusesAutomatic(v)) return { ok: false, skip: true };
            S.zoom = zoom;
            S.video = v;
            bringIntoView(v);
            S.root = playerRoot(v);
            S.root.setAttribute('data-harbor-pip-root', '');
            v.setAttribute('data-harbor-pip-video', '');
            for (const node of new Set([document, S.root.getRootNode(), v.getRootNode()])) {
                const style = document.createElement('style');
                style.textContent = css;
                (node.head || node.documentElement || node).appendChild(style);
                S.styles.push(style);
            }
            if (v.controls) { S.controls = true; v.controls = false; }
            markCovers();
            // A page reduced to its video must not hold text focus: a focused search box drops
            // its suggestions over the video.
            const a = document.activeElement;
            if (a && (a.tagName === 'INPUT' || a.tagName === 'TEXTAREA' || a.isContentEditable)) a.blur();
            watch();
            return rect();
        }

        // Reports the next change to the video's rect, re-isolating when the page swaps the
        // element out. Event driven: nothing runs while the page is still.
        function watch() {
            const bump = () => {
                if (S.queued) return;
                S.queued = true;
                requestAnimationFrame(() => {
                    S.queued = false;
                    if (!S.video) return;
                    if (!S.video.isConnected) {
                        isolate(S.zoom, false);
                    } else {
                        for (const el of S.covers) el.removeAttribute('data-harbor-pip-cover');
                        S.covers = [];
                        markCovers();
                    }
                    S.dirty = true;
                    flush();
                });
            };
            const observer = new ResizeObserver(bump);
            observer.observe(S.video);
            const video = S.video;
            const events = ['resize', 'loadedmetadata', 'emptied'];
            events.forEach(e => video.addEventListener(e, bump));
            // Only scrollers that carry the video: a chat scrolling beside it moves nothing.
            const scrolled = e => {
                for (let n = video; n; n = parentOf(n)) if (n === e.target) return bump();
                if (e.target === document) bump();
            };
            addEventListener('resize', bump);
            addEventListener('scroll', scrolled, { capture: true, passive: true });
            S.unwatch = () => {
                observer.disconnect();
                events.forEach(e => video.removeEventListener(e, bump));
                removeEventListener('resize', bump);
                removeEventListener('scroll', scrolled, { capture: true });
            };
        }

        function flush() {
            if (!S.dirty || !S.waiter) return;
            S.dirty = false;
            const r = rect(), key = JSON.stringify(r);
            if (r.ok && key === S.sent) return;
            S.sent = key;
            const waiter = S.waiter;
            S.waiter = null;
            waiter(r);
        }

        function next() {
            if (S.waiter) S.waiter({ ok: false, ended: true });
            return new Promise(resolve => { S.waiter = resolve; flush(); });
        }

        function restore(finished) {
            if (S.unwatch) S.unwatch();
            if (S.root) S.root.removeAttribute('data-harbor-pip-root');
            if (S.video) {
                S.video.removeAttribute('data-harbor-pip-video');
                if (S.controls) S.video.controls = true;
            }
            for (const el of S.covers) el.removeAttribute('data-harbor-pip-cover');
            for (const el of S.styles) el.remove();
            Object.assign(S, { root: null, video: null, controls: false, covers: [], styles: [], unwatch: null, sent: null });
            if (!finished) return;
            if (S.scroll && S.scroll.url === location.href) {
                for (const [n, x, y] of S.scroll.at) n.scrollTo({ left: x, top: y, behavior: 'instant' });
            }
            S.scroll = null;
            if (S.waiter) {
                const waiter = S.waiter;
                S.waiter = null;
                waiter({ ok: false, ended: true });
            }
        }

        return { isolate, next, restore, video: () => S.video };
    })();
    """
}

// MARK: - View

/// The video itself, sized to the real aspect ratio of the media so nothing letterboxes, sitting
/// directly above `MediaControlsView`.
struct SidebarPiPView: View {
    @Environment(BrowserWindowState.self) var windowState

    @State private var isHovering = false

    private var controller: SidebarPiPController? { windowState.sidebarPiPController }

    var body: some View {
        if let controller, controller.isDocked, let webView = controller.webView {
            SidebarPiPWebViewHost(controller: controller, webView: webView, videoRect: controller.videoRect)
                .aspectRatio(controller.aspect, contentMode: .fit)
                .clipShape(HarborDesign.Radius.shape(HarborDesign.Radius.md))
                .harborElevation(.raised)
                .overlay {
                    if isHovering, controller.isReady { controls(controller) }
                }
                // The video is watched from other apps, so hover must not wait for a click.
                .onHoverTracking(always: true) { hovering in
                    withAnimation(HarborDesign.Motion.quick) { isHovering = hovering }
                }
                .gesture(DragGesture(minimumDistance: HarborDesign.Spacing.md)
                    .onChanged { _ in controller.popOut() })
                // The view is hosted from the start so the page never leaves the window; the video
                // rises out of the bar once its isolated frame is on screen.
                .modifier(CollapseModifier(heightScale: controller.isReady ? 1 : CollapseModifier.collapsed))
                .opacity(controller.isReady ? 1 : 0)
                .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
                .transition(.asymmetric(insertion: .identity, removal: .collapseIntoBar))
        } else if let controller, controller.isFloating, controller.isDragging {
            dropZone(controller)
        }
    }

    private func dropZone(_ controller: SidebarPiPController) -> some View {
        HarborDesign.Radius.shape(HarborDesign.Radius.md)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [HarborDesign.Spacing.sm, HarborDesign.Spacing.xs]))
            .overlay { Label("Dock video", systemImage: "pip.enter").font(HarborDesign.Font.caption) }
            .foregroundStyle(controller.isOverDock ? .primary : .tertiary)
            .aspectRatio(controller.aspect, contentMode: .fit)
            .background(DockZoneReporter(controller: controller))
            .padding(.horizontal, HarborDesign.Spacing.sidebarInset)
    }

    private func controls(_ controller: SidebarPiPController) -> some View {
        PiPControls(controller: controller, corner: ("Pop Out", "pip.exit", { controller.popOut() })) {
            withAnimation(HarborDesign.Motion.quick) {
                isHovering = false
                controller.exit()
            }
        }
        .transition(.opacity)
    }
}

// MARK: - Web view host

/// Crops the web view down to the video's rectangle. The page lays out at a normal desktop size
/// and keeps it; a layer transform on the clipping container scales the video's rect to fill the
/// sidebar slot.
private struct SidebarPiPWebViewHost: NSViewRepresentable {
    let controller: SidebarPiPController
    let webView: WKWebView
    let videoRect: CGRect

    func makeNSView(context: Context) -> SidebarPiPCropView {
        SidebarPiPCropView(frame: .zero)
    }

    func updateNSView(_ container: SidebarPiPCropView, context: Context) {
        // A host on its way out still gets updates; it must not take back a view that floated.
        guard !controller.isFloating, controller.webView === webView else { return }
        if webView.superview !== container {
            // No autoresizing and no frame change: the page must keep the layout it was measured
            // in. Cropping needs no particular size, and reflowing costs a white repaint.
            webView.autoresizingMask = []
            container.addSubview(webView)
        }
        container.crop = videoRect
    }

    static func dismantleNSView(_ container: SidebarPiPCropView, coordinator: ()) {
        container.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Flipped so its coordinates match the page's. A web view inside one ignores the pointer
/// (`FocusableWKWebView`), since AppKit would map it without the crop's transform.
final class SidebarPiPCropView: NSView {
    var crop: CGRect = .zero { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // Drawn over the tab list's hidden rows, whose drags would otherwise start from here.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { HarborDragSessionManager.shared.addDragBarrier(self) }
    }

    // The page gets no clicks or scrolls: a click would select its tab, a scroll would move
    // the video out from under the crop.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func layout() {
        super.layout()
        guard crop.width > 1, crop.height > 1, bounds.width > 1, bounds.height > 1, let layer else { return }
        // Fill on both axes, centred, so a rect whose aspect lags the slot trims video rather
        // than showing page around it.
        let scale = max(bounds.width / crop.width, bounds.height / crop.height)
        let inset = CGPoint(x: (bounds.width - crop.width * scale) / 2, y: (bounds.height - crop.height * scale) / 2)
        layer.sublayerTransform = CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-crop.minX, -crop.minY, 0),
                                CATransform3DMakeScale(scale, scale, 1)),
            CATransform3DMakeTranslation(inset.x, inset.y, 0))
    }
}

// MARK: - Controls

/// The system PiP window's controls: scrim squircles at its sizes, scaled down below a 300pt-wide
/// player. Close sends the video back to its tab still playing, which the media bar then holds.
private struct PiPControls: View {
    weak var controller: SidebarPiPController?
    /// Top right: pop out when docked, back to the sidebar when afloat.
    let corner: (label: String, symbol: String, action: () -> Void)
    let onClose: () -> Void
    /// Each button's frame, so the float panel can keep every other click for its drag.
    var onButtonFrames: ([CGRect]) -> Void = { _ in }
    /// False while the float panel keeps the controls hidden.
    var isActive = true

    private let referenceWidth: CGFloat = 300

    @State private var playback: (time: Double, duration: Double)?
    /// The time under the pointer during a drag; the video seeks on release.
    @State private var scrubTime: Double?

    var body: some View {
        GeometryReader { proxy in
            let scale = min(1, max(0.6, proxy.size.width / referenceWidth))
            ZStack {
                HStack(spacing: HarborDesign.Spacing.lg * scale) {
                    button("Rewind", "gobackward.10", HarborDesign.Size.pipSkip * scale) { controller?.seek(-10) }
                    button(isPlaying ? "Pause" : "Play", isPlaying ? "pause.fill" : "play.fill",
                           HarborDesign.Size.pipPlay * scale) { controller?.togglePlay() }
                    button("Forward", "goforward.10", HarborDesign.Size.pipSkip * scale) { controller?.seek(10) }
                }

                HStack(spacing: HarborDesign.Spacing.sm * scale) {
                    button("Close", "xmark", HarborDesign.Size.chromeControl * scale, action: onClose)
                    Spacer()
                    button("Return to Tab", "arrow.up.forward.app", HarborDesign.Size.chromeControl * scale) {
                        controller?.returnToTab()
                    }
                    button(corner.label, corner.symbol, HarborDesign.Size.chromeControl * scale, action: corner.action)
                }
                .padding(HarborDesign.Spacing.sm * scale)
                .frame(maxHeight: .infinity, alignment: .top)

                if let playback {
                    scrubber(playback, scale: scale)
                        .padding(HarborDesign.Spacing.sm * scale)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        // ponytail: asked twice a second while the pointer is over the video; switch to the
        // page's timeupdate events if this ever shows in a profile.
        .task(id: isActive) {
            while isActive, !Task.isCancelled {
                controller?.playback { playback = $0 }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        // Media controls stay dark over any video, whatever the app's appearance.
        .environment(\.colorScheme, .dark)
        .onPreferenceChange(PiPButtonFrames.self) { onButtonFrames($0) }
    }

    private var isPlaying: Bool {
        guard let session = controller?.session else { return false }
        return session.hasPlayingVideo || session.hasPlayingAudio
    }

    private func scrubber(_ playback: (time: Double, duration: Double), scale: CGFloat) -> some View {
        let time = scrubTime ?? playback.time
        let shape = HarborDesign.Radius.shape(HarborDesign.Size.pipScrub / 2)
        return HStack(spacing: HarborDesign.Spacing.sm * scale) {
            Text(Self.clock(time))
            GeometryReader { proxy in
                let at = { (x: CGFloat) in playback.duration * min(1, max(0, x / proxy.size.width)) }
                ZStack(alignment: .leading) {
                    shape.fill(.tertiary)
                    shape.fill(.white).frame(width: proxy.size.width * min(1, time / playback.duration))
                }
                .frame(height: HarborDesign.Size.pipScrub)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { scrubTime = at($0.location.x) }
                    .onEnded {
                        let target = at($0.location.x)
                        controller?.scrub(to: target)
                        self.playback?.time = target
                        scrubTime = nil
                    })
            }
            Text(Self.clock(playback.duration))
        }
        .font(HarborDesign.Font.caption.monospacedDigit())
        .foregroundStyle(.white)
        .frame(height: HarborDesign.Size.rowButton * scale)
        .padding(.horizontal, HarborDesign.Spacing.sm * scale)
        .harborMediaControl(in: HarborDesign.Radius.shape(HarborDesign.Radius.md))
        .background(GeometryReader {
            Color.clear.preference(key: PiPButtonFrames.self, value: [$0.frame(in: .global)])
        })
    }

    private static func clock(_ seconds: Double) -> String {
        Duration.seconds(Int(seconds)).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    private func button(_ label: String, _ symbol: String, _ diameter: CGFloat,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .contentShape(HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .harborMediaControl(in: HarborDesign.Radius.shape(HarborDesign.Radius.lg))
        .help(label)
        .accessibilityLabel(label)
        .background(GeometryReader {
            Color.clear.preference(key: PiPButtonFrames.self, value: [$0.frame(in: .global)])
        })
    }
}

private struct PiPButtonFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) { value += nextValue() }
}

/// Clicks on a panel that never becomes key are all first clicks.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Tells the controller where the sidebar's drop zone is on screen.
private struct DockZoneReporter: NSViewRepresentable {
    let controller: SidebarPiPController

    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { controller.dockZoneView = view }
}

// MARK: - Float panel

/// Above every app and on every space, fullscreen ones included, without taking focus.
private final class SidebarPiPFloatPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        contentAspectRatio = contentRect.size
        contentMinSize = CGSize(width: 240, height: 240 * contentRect.height / contentRect.width)
    }
}

/// The panel's content: the cropped video, hover controls, and the mouse-down that starts a drag.
private final class FloatRootView: NSView {
    weak var controller: SidebarPiPController? { didSet { controls.rootView = makeControls(active: !controls.isHidden) } }
    let container = SidebarPiPCropView(frame: .zero)
    private lazy var controls = FirstMouseHostingView(rootView: makeControls())
    /// In the controls' flipped space; a click anywhere else starts a drag.
    private var buttonFrames: [CGRect] = []

    init(controller: SidebarPiPController, frame: CGRect) {
        self.controller = controller
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = HarborDesign.Radius.md
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        controls.isHidden = true
        for view in [container, controls] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeControls(active: Bool = false) -> PiPControls {
        PiPControls(
            controller: controller,
            corner: ("Return to Sidebar", "pip.enter", { [weak self] in self?.controller?.dock() }),
            onClose: { [weak self] in self?.controller?.exit() },
            onButtonFrames: { [weak self] in self?.buttonFrames = $0 },
            isActive: active
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !controls.isHidden, let superview else { return super.hitTest(point) }
        let local = controls.convert(point, from: superview)
        if buttonFrames.contains(where: { $0.contains(local) }) { return super.hitTest(point) }
        return frame.contains(point) ? self : nil
    }

    override var acceptsFirstResponder: Bool { true }

    // The panel never becomes key, so every click is a first click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { controller?.dock() } else { controller?.trackDrag() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }
    override func mouseExited(with event: NSEvent) { setHovered(false) }

    /// A panel that opens or stops under the pointer gets no mouseEntered.
    func syncHover() {
        guard let window else { return }
        setHovered(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }

    private func setHovered(_ hovered: Bool) {
        if hovered { updatePinchTap() }
        guard controls.isHidden == hovered else { return }
        controls.isHidden = !hovered
        controls.rootView = makeControls(active: hovered)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        controller?.settleOnScreen()
        controller?.rememberFloat()
    }

    // MARK: Trackpad

    /// The width before a two-finger double tap zoomed in, so the next one returns to it.
    private var widthBeforeSmartZoom: CGFloat?
    /// Keeps the rest of a two-finger move coming to Harbor once the player slides out from
    /// under the pointer.
    private var capture: PiPScrollCapture?
    private var captureTimeout: DispatchWorkItem?
    /// Sees the player's scrolls and pinches before AppKit picks a view for them.
    private var gestureMonitors: [Any] = []
    private var isMoving = false
    private var isPinching = false

    /// Scrolls and pinches are taken from the event stream rather than from this view's own
    /// handlers. AppKit sends a scroll to the view a gesture first touched, which under the
    /// player's buttons is the controls' SwiftUI host, and it ate them: the player only moved
    /// on the glide after the fingers lifted. macOS sends a pinch to the active window, which
    /// the player never is. A local monitor sees both while Harbor is the app receiving them;
    /// the global one only watches a pinch meant for another app, and cannot keep it from that
    /// app.
    private func setGestureMonitors(_ on: Bool) {
        if on, gestureMonitors.isEmpty {
            let types: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .smartMagnify]
            if let local = NSEvent.addLocalMonitorForEvents(matching: types, handler: { [weak self] event in
                guard let self, self.takeGesture(event) else { return event }
                return nil
            }) { gestureMonitors.append(local) }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: [.magnify, .smartMagnify], handler: { [weak self] event in
                _ = self?.takeGesture(event)
            }) { gestureMonitors.append(global) }
        } else if !on {
            gestureMonitors.forEach(NSEvent.removeMonitor)
            gestureMonitors = []
        }
    }

    /// Whether `event` moves or resizes the player: a gesture already under way, or one that
    /// starts with the pointer on it.
    private func takeGesture(_ event: NSEvent) -> Bool {
        guard let window, window.isVisible else { return false }
        let overPlayer = window.frame.contains(NSEvent.mouseLocation)
        switch event.type {
        case .scrollWheel:
            // A mouse wheel has no direction to follow and keeps scrolling whatever it is over.
            // A move starts when the fingers do, not when they only rest, and never from the
            // glide of a scroll that began elsewhere.
            let starts = overPlayer && (event.phase == .began || event.phase == .changed)
            guard event.hasPreciseScrollingDeltas, isMoving || starts else { return false }
            moveWithFingers(event)
            return true
        case .magnify, .smartMagnify:
            guard isPinching || overPlayer else { return false }
            pinch(event)
            return true
        default:
            return false
        }
    }

    /// Two fingers move the player, following the fingers whichever way scrolling is set, and
    /// a flick sends it gliding on the system's own momentum.
    private func moveWithFingers(_ event: NSEvent) {
        guard let window else { return }
        if !isMoving {
            isMoving = true
            // The pointer stays put while the player moves, so the next scroll would reach
            // whatever is under it: a clear window over the screen keeps it coming here.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? window.screen {
                capture = PiPScrollCapture(screen: screen, onScroll: { [weak self] in _ = self?.takeGesture($0) },
                                           onClick: { [weak self] in self?.endMove() })
            }
        }
        if event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
            let sign: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
            var frame = window.frame
            frame.origin.x += sign * event.scrollingDeltaX
            frame.origin.y -= sign * event.scrollingDeltaY
            window.setFrameOrigin(Self.keptOnScreen(frame).origin)
        }
        // Ends once the fingers lift and any glide after them settles. A gap in events ends it
        // too, so a lost end event can never leave the screen covered.
        let settled = event.momentumPhase == .ended || event.momentumPhase == .cancelled
        let lifted = event.phase == .ended || event.phase == .cancelled
        scheduleMoveEnd(after: settled ? 0 : (lifted ? 0.12 : 0.4))
    }

    private func scheduleMoveEnd(after delay: TimeInterval) {
        captureTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endMove() }
        captureTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func endMove() {
        captureTimeout?.cancel()
        captureTimeout = nil
        capture?.close()
        capture = nil
        guard isMoving else { return }
        isMoving = false
        window?.invalidateShadow()
        controller?.settleOnScreen()
        controller?.rememberFloat()
        syncHover()
    }

    /// Pinching out zooms the player and pinching in shrinks it, around the point under the
    /// fingers, keeping the video's shape. A two-finger double tap zooms in, and the next one
    /// goes back.
    private func pinch(_ event: NSEvent) {
        guard let window else { return }
        let anchor = NSEvent.mouseLocation
        if event.type == .smartMagnify {
            let width: CGFloat
            if let previous = widthBeforeSmartZoom {
                width = previous
                widthBeforeSmartZoom = nil
            } else {
                widthBeforeSmartZoom = window.frame.width
                width = window.frame.width * 1.8
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = HarborDesign.Motion.standardDuration
                window.animator().setFrame(Self.resized(window, width: width, around: anchor), display: true)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.window?.invalidateShadow()
                    self?.controller?.rememberFloat()
                }
            }
            return
        }
        resize(by: event.magnification, ended: event.phase == .ended || event.phase == .cancelled)
    }

    private func resize(by magnification: CGFloat, ended: Bool) {
        guard let window else { return }
        isPinching = !ended
        if magnification != 0 {
            window.setFrame(Self.resized(window, width: window.frame.width * (1 + magnification), around: NSEvent.mouseLocation),
                            display: true)
            widthBeforeSmartZoom = nil
        }
        if ended {
            // A borderless window keeps the shadow of its old size until told otherwise, which
            // drew square corners around the rounded player.
            window.invalidateShadow()
            controller?.rememberFloat()
        }
    }

    /// A pinch read from the session's event stream by `PiPPinchTap`, for when another app is
    /// in front. Taken, and kept from that app, while the pointer is on the player.
    fileprivate func tapPinch(magnification: CGFloat, ended: Bool) -> Bool {
        guard let window, window.isVisible, isPinching || window.frame.contains(NSEvent.mouseLocation) else { return false }
        resize(by: magnification, ended: ended)
        return true
    }

    /// Starts the tap when the setting is on and Harbor has Accessibility access. Checked each
    /// time the pointer arrives, so turning the setting on works without reopening the player.
    private func updatePinchTap() {
        if window != nil, UserDefaults.standard.bool(forKey: HarborSettingsService.pipPinchOverOtherAppsKey) {
            PiPPinchTap.shared.start(for: self)
        } else {
            PiPPinchTap.shared.stop(for: self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setGestureMonitors(window != nil)
        updatePinchTap()
        if window == nil { endMove() }
        // Unplugging a display must not strand the player on one that is gone.
        NotificationCenter.default.removeObserver(self, name: NSApplication.didChangeScreenParametersNotification, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller?.settleOnScreen() }
            }
        }
    }

    /// `window` at `width`, clamped between its minimum and most of the screen, with the point
    /// `anchor` staying where it was on the player.
    private static func resized(_ window: NSWindow, width: CGFloat, around anchor: CGPoint) -> CGRect {
        let frame = window.frame
        let maxWidth = (window.screen?.visibleFrame.width ?? 1600) * 0.8
        let newWidth = min(max(width, window.contentMinSize.width), maxWidth)
        let newHeight = newWidth * frame.height / max(frame.width, 1)
        let share = CGPoint(x: (anchor.x - frame.minX) / max(frame.width, 1),
                            y: (anchor.y - frame.minY) / max(frame.height, 1))
        let resized = CGRect(x: anchor.x - share.x * newWidth, y: anchor.y - share.y * newHeight,
                             width: newWidth, height: newHeight)
        return keptOnScreen(resized)
    }

    /// Moved back inside the screens' usable area, so a gesture cannot push the player away.
    private static func keptOnScreen(_ frame: CGRect) -> CGRect {
        pipKeptOnScreen(frame)
    }
}

// MARK: - Pinch tap

/// macOS sends a pinch only to the app in front, so a floating player over another app never
/// saw one. With Accessibility access (Settings > General), an event tap reads the session's
/// pinches as they arrive and hands the player those made with the pointer on it; the rest go
/// on untouched. It runs only while a floating player is open.
@MainActor
private final class PiPPinchTap {
    static let shared = PiPPinchTap()

    private weak var player: FloatRootView?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    /// The raw trackpad gesture event, before AppKit turns it into `magnify` for the front app,
    /// and the fields of a zoom: its type, its amount and its phase.
    private static let gestureEventType: UInt32 = 29
    private static let gestureKind = CGEventField(rawValue: 110)!
    private static let zoomKind: Int64 = 8
    private static let zoomAmount = CGEventField(rawValue: 113)!
    private static let gesturePhase = CGEventField(rawValue: 132)!
    private static let phaseEnded: Int64 = 4
    private static let phaseCancelled: Int64 = 8

    func start(for player: FloatRootView) {
        self.player = player
        guard tap == nil, AXIsProcessTrusted() else { return }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<PiPPinchTap>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated { tap.handle(type: type, event: event) }
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << CGEventMask(Self.gestureEventType),
            callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        self.source = source
    }

    func stop(for player: FloatRootView) {
        guard self.player == nil || self.player === player else { return }
        self.player = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS turns a tap off when it is slow or the user interacts with secure input; turn
        // it back on rather than lose the player's pinches.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == Self.gestureEventType,
              event.getIntegerValueField(Self.gestureKind) == Self.zoomKind,
              let player else { return Unmanaged.passUnretained(event) }
        let phase = event.getIntegerValueField(Self.gesturePhase)
        let taken = player.tapPinch(magnification: event.getDoubleValueField(Self.zoomAmount),
                                    ended: phase == Self.phaseEnded || phase == Self.phaseCancelled)
        return taken ? nil : Unmanaged.passUnretained(event)
    }
}

// MARK: - Scroll capture

/// A clear window over one screen, just above the player, that takes scroll events while two
/// fingers move the player. Without it the move stopped as soon as the player left the pointer,
/// and whatever was under the pointer scrolled instead. A click ends it.
@MainActor
private final class PiPScrollCapture {
    private let panel: NSPanel

    init(screen: NSScreen, onScroll: @escaping (NSEvent) -> Void, onClick: @escaping () -> Void) {
        panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Set explicitly, so the clear window takes events everywhere rather than letting them
        // through where it draws nothing.
        panel.ignoresMouseEvents = false
        let view = CaptureView()
        view.onScroll = onScroll
        view.onClick = onClick
        panel.contentView = view
        panel.orderFrontRegardless()
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }

    private final class CaptureView: NSView {
        var onScroll: ((NSEvent) -> Void)?
        var onClick: (() -> Void)?
        override func scrollWheel(with event: NSEvent) { onScroll?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onClick?() }
        override func rightMouseDown(with event: NSEvent) { onClick?() }
    }
}

// MARK: - Transition

private struct CollapseModifier: ViewModifier {
    /// The bar's height as a share of the video's: where the video rises from and returns to.
    static let collapsed: CGFloat = 0.04
    let heightScale: CGFloat

    func body(content: Content) -> some View {
        // Height only, at full width, anchored to the bottom: the video flattens down into the
        // bar's shape rather than shrinking toward a point in the middle. scaleEffect is a
        // render transform, so the web view is never re-laid out mid-animation.
        content.scaleEffect(x: 1, y: heightScale, anchor: .bottom)
    }
}

extension AnyTransition {
    /// The video collapsing into the media bar that takes its place.
    static var collapseIntoBar: AnyTransition {
        .modifier(active: CollapseModifier(heightScale: CollapseModifier.collapsed),
                  identity: CollapseModifier(heightScale: 1))
    }
}
