#if canImport(AppKit)

import SwiftUI

// Harbor: a trackpad pager of its own instead of NSPageController. The lift hands off to a
// critically damped spring that starts at the fingers' speed, as Arc's space swipe does.
extension PlatformPageView: NSViewRepresentable {

    func makeNSView(context: Context) -> SwipePagerView {
        let view = SwipePagerView()
        view.coordinator = context.coordinator
        context.coordinator.pager = view
        context.coordinator.show(selection)
        return view
    }

    func updateNSView(_ view: SwipePagerView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.refresh(to: selection, animated: context.transaction.animation != nil)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator {
        var parent: PlatformPageView
        weak var pager: SwipePagerView?
        private(set) var current: SelectionValue?
        private var views: [SelectionValue: HostingView] = [:]

        init(_ parent: PlatformPageView) {
            self.parent = parent
        }

        func view(for value: SelectionValue) -> HostingView {
            if let view = views[value] {
                view.rootView = parent.content(value)
                return view
            }
            let view = HostingView(rootView: parent.content(value))
            views[value] = view
            return view
        }

        /// Shows `value` with no animation and drops pages that are no longer neighbours.
        func show(_ value: SelectionValue) {
            current = value
            let keep = Set([value, parent.previous(value), parent.next(value)].compactMap { $0 })
            views = views.filter { keep.contains($0.key) }
            pager?.present(view(for: value))
            warm()
        }

        /// The space a page belongs to.
        func value(for view: HostingView) -> SelectionValue? {
            views.first { $0.value === view }?.key
        }

        /// Builds the neighbours' pages ahead of the swipe and parks them just off the edge. A
        /// page built when the fingers land has to lay out its favorites and tabs right then,
        /// which was the stall at the start of a swipe.
        func warm() {
            guard let current else { return }
            var neighbours: [(view: HostingView, forward: Bool)] = []
            if let previous = parent.previous(current) { neighbours.append((view(for: previous), false)) }
            if let next = parent.next(current) { neighbours.append((view(for: next), true)) }
            pager?.warm(neighbours)
        }

        func refresh(to value: SelectionValue, animated: Bool) {
            guard value != current else {
                if let current { _ = view(for: current) }
                // The parked neighbours read the same state, or they would go stale while waiting.
                warm()
                return
            }
            guard animated, let pager, let from = current else { return show(value) }
            let forward = parent.next(from) == value
            pager.animate(to: view(for: value), forward: forward) { [weak self] in self?.show(value) }
        }

        func neighbour(forward: Bool) -> SelectionValue? {
            guard let current else { return nil }
            return forward ? parent.next(current) : parent.previous(current)
        }

        func commit(_ value: SelectionValue) {
            show(value)
            parent.selection = value
        }

        /// A swipe that will land: the selection changes now, as Arc switches the moment the
        /// fingers lift, and `show` settles the views once the slide is over. `current` moves
        /// first so the update the selection causes does not cut the slide short.
        func select(_ value: SelectionValue) {
            current = value
            parent.selection = value
        }
    }

    // MARK: - Views

    final class SwipePagerView: NSView {
        weak var coordinator: Coordinator?
        private var page: HostingView?
        private var incoming: HostingView?
        private var isTracking = false
        /// True from when a slide is handed to Core Animation until it ends. A new swipe may
        /// take over a slide in progress; `slideGeneration` stops the old slide's end from
        /// settling views the new swipe now holds.
        private var isSliding = false
        private var slideGeneration = 0
        /// The neighbouring pages, parked just outside the edge, ready to be swiped in.
        private var warmViews: [(view: HostingView, forward: Bool)] = []

        /// How long the slide reads as taking. A fixed 0.18 s ease-out felt abrupt once the
        /// space switch stopped dropping its frames.
        private static var slideDuration: TimeInterval { 0.34 }
        private static var switchDelay: TimeInterval { 1.0 / 60 }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func present(_ view: HostingView) {
            if let incoming, incoming !== view { incoming.removeFromSuperview() }
            incoming = nil
            if let page, page !== view { page.removeFromSuperview() }
            page = view
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            if view.superview !== self { addSubview(view) }
        }

        override func layout() {
            super.layout()
            guard !isTracking else { return }
            page?.frame = bounds
            parkWarmViews()
        }

        func warm(_ items: [(view: HostingView, forward: Bool)]) {
            for old in warmViews where !items.contains(where: { $0.view === old.view })
                && old.view !== page && old.view !== incoming {
                old.view.removeFromSuperview()
            }
            warmViews = items
            guard !isTracking else { return }
            parkWarmViews()
        }

        private func parkWarmViews() {
            for item in warmViews where item.view !== page && item.view !== incoming {
                item.view.autoresizingMask = []
                item.view.frame = bounds.offsetBy(dx: item.forward ? bounds.width : -bounds.width, dy: 0)
                if item.view.superview !== self { addSubview(item.view) }
            }
        }

        /// Stops a slide where it is on screen and hands the pages to the next swipe. The page
        /// nearer the middle becomes the one shown, and the window's space follows it. Returns
        /// where that page stands and the other, still partly in view.
        private func interruptSlide() -> (offset: CGFloat, other: (value: SelectionValue, view: HostingView, forward: Bool)?)? {
            guard let coordinator, let first = page else { return nil }
            slideGeneration += 1
            isSliding = false
            let views = [first, incoming].compactMap { $0 }
            // Where each page is drawn now: its end frame plus the spring's remaining travel.
            let drawn = views.map { $0.layer?.presentation()?.frame.minX ?? $0.frame.minX }
            for (view, x) in zip(views, drawn) {
                view.layer?.removeAnimation(forKey: "harbor.slide")
                view.frame = NSRect(x: x, y: 0, width: bounds.width, height: bounds.height)
            }
            guard views.count == 2, views[1] !== first else { return (first.frame.minX, nil) }
            let firstIsNearer = abs(drawn[0]) <= abs(drawn[1])
            let shown = firstIsNearer ? views[0] : views[1]
            let other = firstIsNearer ? views[1] : views[0]
            page = shown
            incoming = other
            if let value = coordinator.value(for: shown), value != coordinator.current { coordinator.select(value) }
            let forward = other.frame.minX > shown.frame.minX
            return (shown.frame.minX, coordinator.value(for: other).map { ($0, other, forward) })
        }

        /// A programmatic change: the new page slides in from its side.
        func animate(to view: HostingView, forward: Bool, completion: @escaping () -> Void) {
            guard let page, !isTracking else { return completion() }
            place(view)
            setOffset(0, page: page, incoming: view, forward: forward)
            run(to: forward ? -bounds.width : bounds.width, page: page, incoming: view, forward: forward, completion: completion)
        }

        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }

        override func scrollWheel(with event: NSEvent) {
            guard !isTracking || isSliding,
                  event.phase == .began,
                  event.hasPreciseScrollingDeltas,
                  NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  let coordinator
            else { return super.scrollWheel(with: event) }

            // A swipe during a slide takes it over from where it is, instead of being ignored.
            var baseOffset: CGFloat = 0
            var inherited: (value: SelectionValue, view: HostingView, forward: Bool)?
            if isSliding, let taken = interruptSlide() {
                baseOffset = taken.offset
                inherited = taken.other
            }
            guard let page else { return super.scrollWheel(with: event) }

            let previous = coordinator.neighbour(forward: false)
            let next = coordinator.neighbour(forward: true)
            guard previous != nil || next != nil else { return super.scrollWheel(with: event) }

            isTracking = true
            var target = inherited
            var samples: [(amount: CGFloat, time: TimeInterval)] = []
            var playedHaptic = false
            let width = bounds.width

            // Positive amounts drag the page right, toward the previous space.
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: next == nil ? 0 : -1,
                max: previous == nil ? 0 : 1
            ) { [weak self] amount, phase, _, stop in
                guard let self else { stop.pointee = true; return }
                let forward = amount < 0
                if amount != 0, target?.forward != forward, let value = forward ? next : previous {
                    let view = coordinator.view(for: value)
                    target = (value, view, forward)
                    self.place(view)
                }

                switch phase {
                case .began, .changed:
                    samples.append((amount, ProcessInfo.processInfo.systemUptime))
                    if samples.count > 4 { samples.removeFirst() }
                    self.setOffset(baseOffset + amount * width, page: page, incoming: target?.view, forward: target?.forward ?? forward)
                    if !playedHaptic, abs(amount) > 0.15 {
                        playedHaptic = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                case .ended, .cancelled:
                    // Take over from the system's momentum with a short animation of our own.
                    stop.pointee = true
                    let velocity = Self.velocity(samples)
                    // Taking a slide over, the page already stands part way: a shorter pull counts.
                    let pull: CGFloat = baseOffset == 0 ? 0.3 : 0.12
                    let commits = phase == .ended && target.map {
                        $0.forward == (amount < 0)
                            && (abs(amount) > pull || ($0.forward ? velocity < -0.8 : velocity > 0.8))
                    } == true
                    if let target, commits {
                        self.run(to: target.forward ? -width : width, page: page, incoming: target.view,
                                 forward: target.forward, velocity: velocity) {
                            self.isTracking = false
                            coordinator.show(target.value)
                        }
                        // The space changes a frame after the lift. Changed in the same pass, the
                        // window's work for it (its page, data store, every view reading the
                        // space) ran before the slide reached Core Animation and stalled it. A
                        // frame later the slide is already on the render server, which carries it
                        // through that work.
                        DispatchQueue.main.asyncAfter(deadline: .now() + Self.switchDelay) {
                            coordinator.select(target.value)
                        }
                    } else {
                        let incoming = target?.view
                        self.run(to: 0, page: page, incoming: incoming, forward: target?.forward ?? true, velocity: velocity) {
                            incoming?.removeFromSuperview()
                            self.incoming = nil
                            self.isTracking = false
                            page.frame = self.bounds
                            // The page that went back to its slot leaves the park; put it back.
                            coordinator.warm()
                        }
                    }
                default:
                    break
                }
            }
        }

        private func place(_ view: HostingView) {
            if let incoming, incoming !== view { incoming.removeFromSuperview() }
            incoming = view
            view.autoresizingMask = []
            view.frame = bounds
            if view.superview !== self { addSubview(view) }
        }

        private func setOffset(_ offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool) {
            page.frame = bounds.offsetBy(dx: offset, dy: 0)
            incoming?.frame = bounds.offsetBy(dx: offset + (forward ? bounds.width : -bounds.width), dy: 0)
        }

        /// Slides both pages to `offset`. `velocity` is the gesture's, in widths per second; the
        /// spring starts at it, so a flick keeps its speed and a slow drag settles gently. The
        /// pages take their final frames at once and an additive spring on their layers covers
        /// the distance, all on the render server.
        private func run(to offset: CGFloat, page: NSView, incoming: NSView?, forward: Bool,
                         velocity: CGFloat = 0, completion: @escaping () -> Void) {
            let width = bounds.width
            let generation = slideGeneration
            isSliding = true
            let travel = offset - page.frame.minX
            let spring = CASpringAnimation(perceptualDuration: Self.slideDuration, bounce: 0)
            spring.keyPath = "position.x"
            spring.isAdditive = true
            spring.fromValue = -travel
            spring.toValue = 0
            // In units of the whole travel per second; a gesture moving away from the target
            // starts the spring from rest.
            if abs(travel) > 1 { spring.initialVelocity = min(max(velocity * width / travel, 0), 30) }
            // Cut where less than a pixel is left: until the slide ends no new swipe can start.
            spring.duration = min(spring.settlingDuration, Self.slideDuration + 0.1)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    // A swipe that took the slide over has settled these views itself.
                    guard generation == self.slideGeneration else { return }
                    self.isSliding = false
                    completion()
                }
            }
            page.frame = bounds.offsetBy(dx: offset, dy: 0)
            incoming?.frame = bounds.offsetBy(dx: offset + (forward ? width : -width), dy: 0)
            for view in [page, incoming] { view?.layer?.add(spring, forKey: "harbor.slide") }
            CATransaction.commit()
        }

        /// Gesture amount per second over the last few samples, so a quick flick commits.
        private static func velocity(_ samples: [(amount: CGFloat, time: TimeInterval)]) -> CGFloat {
            guard let first = samples.first, let last = samples.last, last.time > first.time else { return 0 }
            return (last.amount - first.amount) / (last.time - first.time)
        }
    }

    final class HostingView: NSHostingView<Content> {
        // Scroll views inside forward horizontal swipes up to the pager.
        override func wantsForwardedScrollEvents(for axis: NSEvent.GestureAxis) -> Bool {
            axis == .horizontal
        }
    }
}

struct PlatformPageView_Mac_Previews: PreviewProvider {

    static var previews: some View {
        PageViewBasicExample()
            .pageViewStyle(.scroll)
    }
}

#endif
