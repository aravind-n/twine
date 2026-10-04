import AppKit

/// SwiftUI controls this host; the retained document's visibility belongs to AppKit.
final class FileContentHost<Content: NSView>: NSView {
    let content: Content
    /// WebKit uses native page zoom and a physical viewport, cancelling the ancestor's scale.
    var viewportScale: CGFloat = 1 {
        didSet {
            if viewportScale != oldValue { updateViewportBounds() }
        }
    }
    private let responder: NSView
    private var requestedVisibility: Bool?
    private var visibilityTask: Task<Void, Never>?
    private var focusTask: Task<Void, Never>?

    init(content: Content, responder: NSView) {
        self.content = content
        self.responder = responder
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func setFrameSize(_ newSize: NSSize) {
        // Retained hidden source editors can otherwise keep invalidating window constraints.
        guard frame.size != newSize else { return }
        super.setFrameSize(newSize)
        updateViewportBounds()
    }

    private func updateViewportBounds() {
        guard viewportScale != 1 else {
            if bounds.size != frame.size { setBoundsSize(frame.size) }
            return
        }
        let backing = window?.backingScaleFactor ?? 1
        let size = CGSize(
            width: (frame.width * viewportScale * backing).rounded() / backing,
            height: (frame.height * viewportScale * backing).rounded() / backing)
        if bounds.size != size { setBoundsSize(size) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard requestedVisibility == true, !content.isHidden else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateViewportBounds()
        if let visible = requestedVisibility {
            requestedVisibility = nil
            setVisible(visible)
        }
    }

    func setVisible(_ visible: Bool) {
        guard requestedVisibility != visible else { return }
        requestedVisibility = visible
        visibilityTask?.cancel()
        focusTask?.cancel()
        // Key-view changes can reenter SwiftUI while a representable is updating.
        visibilityTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            if !visible, let current = window?.firstResponder as? NSView {
                if current === content || current.isDescendant(of: content) { window?.makeFirstResponder(nil) }
            }
            content.isHidden = !visible
            if visible, !responder.isHiddenOrHasHiddenAncestor { window?.makeFirstResponder(responder) }
        }
    }

    func requestKeyboardFocus() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, requestedVisibility == true,
                !responder.isHiddenOrHasHiddenAncestor
            else { return }
            window?.makeFirstResponder(responder)
        }
    }
}
