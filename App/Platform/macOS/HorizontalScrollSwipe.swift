#if os(macOS)
import AppKit
import SwiftUI

extension View {
    /// Calls `action` once per horizontal trackpad swipe (or horizontal mouse-wheel tick) over this view,
    /// with `forward` true when swiping towards the next item. SwiftUI drags don't see scroll-wheel events.
    func onHorizontalScrollSwipe(_ action: @escaping @MainActor (_ forward: Bool) -> Void) -> some View {
        background(HorizontalScrollSwipeCatcher(action: action))
    }
}

private struct HorizontalScrollSwipeCatcher: NSViewRepresentable {
    let action: @MainActor (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (@MainActor (Bool) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0
        /// Decided by the first movement of each trackpad gesture so vertical page scrolls pass through untouched.
        private var isHorizontalGesture: Bool?
        private var firedThisGesture = false
        private var lastWheelFire = Date.distantPast

        private static let swipeThreshold: CGFloat = 40
        private static let wheelCooldown: TimeInterval = 0.4

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.consumes(event) ?? false } ? nil : event
            }
        }

        private func consumes(_ event: NSEvent) -> Bool {
            guard let window, event.window === window,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return false }

            // Momentum after a swipe we already handled shouldn't scroll the page sideways.
            if event.phase.isEmpty && !event.momentumPhase.isEmpty {
                return firedThisGesture
            }

            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas {
                guard abs(dx) > abs(dy), Date().timeIntervalSince(lastWheelFire) > Self.wheelCooldown else { return false }
                lastWheelFire = Date()
                action?(dx < 0)
                return true
            }

            if event.phase.contains(.began) || event.phase.contains(.mayBegin) {
                accumulated = 0
                isHorizontalGesture = nil
                firedThisGesture = false
            }
            if isHorizontalGesture == nil, dx != 0 || dy != 0 {
                isHorizontalGesture = abs(dx) > abs(dy)
            }
            guard isHorizontalGesture == true else { return false }
            accumulated += dx
            if !firedThisGesture, abs(accumulated) > Self.swipeThreshold {
                firedThisGesture = true
                action?(accumulated < 0)
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                accumulated = 0
            }
            return true
        }
    }
}
#endif
