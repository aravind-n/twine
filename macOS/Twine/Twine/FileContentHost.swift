import AppKit

/// SwiftUI controls this host; the retained document's visibility belongs to AppKit.
final class FileContentHost<Content: NSView>: NSView {
    let content: Content
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard requestedVisibility == true, !content.isHidden else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
