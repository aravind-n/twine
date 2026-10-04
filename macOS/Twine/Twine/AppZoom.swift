import AppKit
import Observation

/// One presentation scale for every window, including sheets and popovers.
@Observable
final class AppZoom {
    private static let percentages = [50, 67, 75, 90, 100, 110, 125, 150, 175, 200]
    private static let preferenceKey = "interfaceZoomPercent"
    private let defaults: UserDefaults
    private var index: Int
    @ObservationIgnored private var keyboardMonitor: Any?

    init(defaults: UserDefaults = WorkflowLaunchPreferences.defaultStore()) {
        self.defaults = defaults
        let saved = defaults.integer(forKey: Self.preferenceKey)
        index = Self.percentages.firstIndex(of: saved) ?? 4
    }

    var scale: CGFloat { CGFloat(Self.percentages[index]) / 100 }
    var canZoomIn: Bool { index < Self.percentages.count - 1 }
    var canZoomOut: Bool { index > 0 }

    func zoomIn() { setIndex(min(index + 1, Self.percentages.count - 1)) }
    func zoomOut() { setIndex(max(index - 1, 0)) }
    func reset() { setIndex(4) }

    private func setIndex(_ index: Int) {
        guard self.index != index else { return }
        self.index = index
        defaults.set(Self.percentages[index], forKey: Self.preferenceKey)
    }

    /// Catch shortcuts before terminals, text editors, or WebKit can consume them. Both the
    /// shifted plus key and the unshifted equals key zoom in on keyboards that share that key.
    func installKeyboardShortcuts() {
        guard keyboardMonitor == nil else { return }
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
    }

    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command || modifiers == [.command, .shift] else { return false }
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoomIn()
        case "-" where modifiers == .command: zoomOut()
        case "0" where modifiers == .command: reset()
        default: return false
        }
        return true
    }

    isolated deinit {
        if let keyboardMonitor { NSEvent.removeMonitor(keyboardMonitor) }
    }
}
