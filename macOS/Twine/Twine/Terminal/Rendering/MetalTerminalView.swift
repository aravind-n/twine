import AppKit
import MetalKit
import OSLog
import SwiftTerm

final class MetalTerminalView: TerminalView {
    var terminalPalettes: CoreTerminalPalettes?

    var twinePalette: TerminalPalette {
        TerminalPalette.resolved(for: effectiveAppearance, palettes: terminalPalettes)
    }
    private(set) var isSendingTerminalResponse = false
    weak var minimapState: TerminalMinimapState?
    var zoomScale: CGFloat = 1 {
        didSet {
            if zoomScale != oldValue { updateRasterizationScale() }
        }
    }

    private func updateRasterizationScale() {
        metalScaleFactorOverride = zoomScale * (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
    }

    var attachmentFailure: ((String) -> Void)?

    override func paste(_ sender: Any) {
        guard attachmentFailure != nil, TerminalAttachments.canRead(.general) else {
            super.paste(sender)
            return
        }
        _ = pasteAttachments(from: .general)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        attachmentFailure != nil && TerminalAttachments.canRead(sender.draggingPasteboard) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !draggingEntered(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard attachmentFailure != nil else { return false }
        window?.makeFirstResponder(self)
        return pasteAttachments(from: sender.draggingPasteboard)
    }

    private func pasteAttachments(from pasteboard: NSPasteboard) -> Bool {
        do {
            guard let text = try TerminalAttachments.text(from: pasteboard) else { return false }
            let bracketed = getTerminal().bracketedPasteMode
            let paste = bracketed ? "\u{1B}[200~" + text + "\u{1B}[201~" : text
            send(data: Array(paste.utf8)[...])
            return true
        } catch {
            attachmentFailure?(error.localizedDescription)
            return false
        }
    }

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isSendingTerminalResponse = true
        defer { isSendingTerminalResponse = false }
        super.send(source: source, data: data)
    }

    /// Called after the terminal takes the keyboard, such as when it's clicked.
    var didFocus: (() -> Void)?

    // SwiftTerm sets this from becomeFirstResponder and resignFirstResponder, which it doesn't let
    // subclasses override.
    override var hasFocus: Bool {
        get { super.hasFocus }
        set {
            super.hasFocus = newValue
            // AppKit can change the first responder during a SwiftUI update, which mustn't change state.
            if newValue { Task { [weak self] in self?.didFocus?() } }
        }
    }

    // Clicks land on SwiftTerm's Metal subview, which doesn't take the keyboard, so take it here.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    private var focusTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var requestedVisibility: Bool?

    /// Hiding the first responder asks AppKit to find another key view. During a representable
    /// update that can reenter SwiftUI's focus graph, so apply visibility after the update returns.
    func setVisible(_ visible: Bool) {
        guard requestedVisibility != visible else { return }
        requestedVisibility = visible
        visibilityTask?.cancel()
        let hidden = !visible
        guard isHidden != hidden else { return }
        visibilityTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            if hidden, window?.firstResponder === self { window?.makeFirstResponder(nil) }
            isHidden = hidden
            if visible { setFrameSize(frame.size) }
            if visible && isSelected { requestKeyboardFocus() }
        }
    }

    var automaticallyFocuses = true {
        didSet {
            guard automaticallyFocuses != oldValue else { return }
            focusTask?.cancel()
            if !automaticallyFocuses {
                releaseKeyboardFocus()
            } else if isSelected {
                requestKeyboardFocus()
            }
        }
    }
    var focusRequest = 0 {
        didSet {
            if focusRequest != oldValue, isSelected { requestKeyboardFocus() }
        }
    }
    var isSelected = true {
        didSet {
            guard isSelected != oldValue else { return }
            focusTask?.cancel()
            if isSelected { requestKeyboardFocus() }
        }
    }

    /// A form over the terminal owns the keyboard, so typing can't reach the shell behind it.
    private func releaseKeyboardFocus() {
        focusTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, !automaticallyFocuses, window?.firstResponder === self else { return }
            window?.makeFirstResponder(nil)
        }
    }

    private func requestKeyboardFocus() {
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            // SwiftUI changes the terminal's visibility and its host's focus in the same update.
            // Request focus after that update has returned, once the selected view is visible.
            await Task.yield()
            guard !Task.isCancelled, let self, automaticallyFocuses, isSelected,
                !isHiddenOrHasHiddenAncestor, let window
            else { return }
            window.makeFirstResponder(self)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        font = .terminal
        changeScrollback(100_000)
        applyTwinePalette()
        registerForDraggedTypes(TerminalAttachments.types)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        font = .terminal
        changeScrollback(100_000)
        applyTwinePalette()
        registerForDraggedTypes(TerminalAttachments.types)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRasterizationScale()
        applyTwinePalette()

        guard window != nil else {
            focusTask?.cancel()
            visibilityTask?.cancel()
            requestedVisibility = nil
            return
        }
        // The selected terminal takes keyboard input without an additional click.
        if isSelected { requestKeyboardFocus() }

        guard !isUsingMetalRenderer else { return }

        do {
            try setUseMetal(true)
        } catch {
            terminalLogger.error(
                "SwiftTerm Metal renderer failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTwinePalette()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard newSize.width > 0, newSize.height > 0 else { return }
        let terminal = getTerminal()
        terminalDelegate?.sizeChanged(source: self, newCols: terminal.cols, newRows: terminal.rows)
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        setFrameSize(frame.size)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateRasterizationScale()
        setFrameSize(frame.size)
    }

    func applyTwinePalette() {
        let palette = twinePalette
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.text
        caretColor = palette.cursor
        selectedTextBackgroundColor = palette.selection
        selectedTextForegroundColor = palette.text
        installColors(palette.ansi)
    }

    func applyTwineFont(_ font: NSFont) {
        // SwiftTerm resets the grid and selection when its font is assigned, even if unchanged.
        guard self.font != font else { return }
        self.font = font
    }
}
