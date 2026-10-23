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
        }

        func refresh(to value: SelectionValue, animated: Bool) {
            guard value != current else {
                if let current { _ = view(for: current) }
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

        /// How long the slide reads as taking. A fixed 0.18 s ease-out felt abrupt once the
        /// space switch stopped dropping its frames.
        private static var slideDuration: TimeInterval { 0.4 }
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
            if !isTracking { page?.frame = bounds }
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
            guard !isTracking,
                  event.phase == .began,
                  event.hasPreciseScrollingDeltas,
                  NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY),
                  let coordinator, let page
            else { return super.scrollWheel(with: event) }

            let previous = coordinator.neighbour(forward: false)
            let next = coordinator.neighbour(forward: true)
            guard previous != nil || next != nil else { return super.scrollWheel(with: event) }

            isTracking = true
            var target: (value: SelectionValue, view: HostingView, forward: Bool)?
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
                    self.setOffset(amount * width, page: page, incoming: target?.view, forward: target?.forward ?? forward)
                    if !playedHaptic, abs(amount) > 0.15 {
                        playedHaptic = true
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                case .ended, .cancelled:
                    // Take over from the system's momentum with a short animation of our own.
                    stop.pointee = true
                    let velocity = Self.velocity(samples)
                    let commits = phase == .ended && target.map {
                        $0.forward == (amount < 0)
                            && (abs(amount) > 0.3 || ($0.forward ? velocity < -0.8 : velocity > 0.8))
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
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
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
