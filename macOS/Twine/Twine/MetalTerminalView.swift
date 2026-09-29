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

        guard let window else { return }
        // The terminal is the folder's primary surface, so it takes keyboard input without a click.
        window.makeFirstResponder(self)

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
