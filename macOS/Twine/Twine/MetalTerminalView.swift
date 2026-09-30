import AppKit
import MetalKit
import OSLog
import SwiftTerm

struct TerminalPalette {
    let background: NSColor
    let text: NSColor
    let ansi: [SwiftTerm.Color]

    static func resolved(for appearance: NSAppearance?) -> Self {
        guard let appearance else {
            return fixedPalette()
        }
        var resolved: Self?
        appearance.performAsCurrentDrawingAppearance {
            resolved = fixedPalette()
        }
        return resolved ?? fixedPalette()
    }

    private static func fixedPalette() -> Self {
        let ansi: [NSColor] = [
            .terminalBlack, .terminalTextRed, .terminalTextGreen, .terminalTextAmber,
            .terminalTextBlue, .terminalTextMagenta, .terminalTextCyan, .terminalWhite,
            .terminalTextMuted, .terminalBrightRed, .terminalBrightGreen, .terminalBrightAmber,
            .terminalBrightBlue, .terminalBrightMagenta, .terminalBrightCyan, .terminalBrightWhite,
        ]
        return Self(
            background: fixed(.terminalBackground),
            text: fixed(.terminalText),
            ansi: ansi.map { SwiftTerm.Color(nsColor: fixed($0)) }
        )
    }

    private static func fixed(_ color: NSColor) -> NSColor {
        guard let resolved = color.usingColorSpace(.sRGB) else { return color }
        return NSColor(
            srgbRed: resolved.redComponent,
            green: resolved.greenComponent,
            blue: resolved.blueComponent,
            alpha: resolved.alphaComponent
        )
    }
}

final class MetalTerminalView: TerminalView {
    private(set) var isSendingTerminalResponse = false
    weak var minimapState: TerminalMinimapState?

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
            if visible && isSelected { requestKeyboardFocus() }
        }
    }

    var automaticallyFocuses = true {
        didSet {
            guard automaticallyFocuses != oldValue else { return }
            focusTask?.cancel()
            if automaticallyFocuses && isSelected { requestKeyboardFocus() }
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
        applyTwinePalette()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        font = .terminal
        applyTwinePalette()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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

    func applyTwinePalette() {
        let palette = TerminalPalette.resolved(for: effectiveAppearance)
        nativeBackgroundColor = palette.background
        nativeForegroundColor = palette.text
        installColors(palette.ansi)
    }

    func applyTwineFont(_ font: NSFont) {
        // SwiftTerm resets the grid and selection when its font is assigned, even if unchanged.
        guard self.font != font else { return }
        self.font = font
    }
}
