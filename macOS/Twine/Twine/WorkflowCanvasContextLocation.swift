import AppKit
import SwiftUI

/// Record the context-click point without taking clicks away from SwiftUI cards or menus.
struct WorkflowCanvasContextLocation: NSViewRepresentable {
    let changed: (CGPoint) -> Void

    func makeNSView(context: Context) -> LocationView { LocationView(changed: changed) }
    func updateNSView(_ view: LocationView, context: Context) { view.changed = changed }

    final class LocationView: NSView {
        var changed: (CGPoint) -> Void
        private var mouseMonitor: Any?
        override var isFlipped: Bool { true }

        init(changed: @escaping (CGPoint) -> Void) {
            self.changed = changed
            super.init(frame: .zero)
            setAccessibilityElement(false)
            let eventTypes: NSEvent.EventTypeMask = [.rightMouseDown, .leftMouseDown]
            let handler: (NSEvent) -> NSEvent? = { [weak self] event in
                guard let self, let window, event.window === window, !isHiddenOrHasHiddenAncestor,
                    event.type == .rightMouseDown || event.modifierFlags.contains(.control)
                else { return event }
                let point = convert(event.locationInWindow, from: nil)
                if bounds.contains(point) { self.changed(point) }
                return event
            }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: eventTypes, handler: handler)
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        isolated deinit {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        }
    }
}
