import AppKit
import MetalKit
import OSLog
import SwiftTerm

struct TerminalPalette {
    let background: NSColor
    let text: NSColor
    let muted: NSColor
    let green: NSColor
    let blue: NSColor
    let amber: NSColor

    var ansi: [SwiftTerm.Color] {
        [
            background, amber, green, amber, blue, blue, blue, text,
            muted, amber, green, amber, blue, blue, blue, text,
        ].map(SwiftTerm.Color.init(nsColor:))
    }

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
        Self(
            background: fixed(.terminalBackground),
            text: fixed(.terminalText),
            muted: fixed(.terminalTextMuted),
            green: fixed(.terminalTextGreen),
            blue: fixed(.terminalTextBlue),
            amber: fixed(.terminalTextAmber)
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

    override func send(source: Terminal, data: ArraySlice<UInt8>) {
        isSendingTerminalResponse = true
        defer { isSendingTerminalResponse = false }
        super.send(source: source, data: data)
    }

    private var focusTask: Task<Void, Never>?
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
}
