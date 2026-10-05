import AppKit
import OSLog
import TwineSyntax

private let syntaxLogger = Logger(subsystem: "com.twineproject.Twine", category: "file-syntax")

/// A document's asynchronous syntax session. Rendering never changes its editing buffer.
final class FileSyntaxHighlighter {
    private weak var textView: NSTextView?
    private let parser = SyntaxParser()
    private let renderer = FileSyntaxRenderer()
    private var language: SyntaxLanguage?
    private var loadID: UUID?
    private var revision: UInt64 = 0
    private var isVisible = false
    private var needsHighlight = true
    private(set) var pendingTask: Task<Void, Never>?

    func attach(to view: NSTextView) {
        textView = view
        renderer.attach(to: view)
    }

    func update(language: SyntaxLanguage?, loadID: UUID, isVisible: Bool) {
        let changed = self.language != language || self.loadID != loadID
        let becameVisible = isVisible && !self.isVisible
        self.language = language
        self.loadID = loadID
        self.isVisible = isVisible
        renderer.isVisible = isVisible
        if changed {
            invalidate()
        } else if !isVisible {
            pendingTask?.cancel()
            pendingTask = nil
            needsHighlight = true
        }
        if changed || becameVisible || needsHighlight { schedule() }
    }

    func textDidChange() {
        invalidate()
        schedule()
    }

    func refreshViewport() { renderer.refreshViewport() }

    func appearanceDidChange() { renderer.invalidate() }

    func detach() {
        pendingTask?.cancel()
        pendingTask = nil
        revision &+= 1
        renderer.detach()
        textView = nil
    }

    private func invalidate() {
        revision &+= 1
        pendingTask?.cancel()
        pendingTask = nil
        needsHighlight = true
        renderer.replaceTokens([])
    }

    private func schedule() {
        guard needsHighlight, isVisible, let view = textView, !view.hasMarkedText() else { return }
        guard let language else {
            needsHighlight = false
            return
        }
        needsHighlight = false
        let source = view.string
        let requestRevision = revision
        pendingTask = Task { [weak self, parser] in
            do {
                // Coalesce typing before crossing to the parser's isolated executor.
                try await Task.sleep(for: .milliseconds(25))
                let tokens = try await parser.highlight(source, language: language)
                try Task.checkCancellation()
                guard let self, revision == requestRevision, self.language == language,
                    isVisible, let view = textView, !view.hasMarkedText()
                else { return }
                renderer.replaceTokens(tokens)
            } catch is CancellationError {
                return
            } catch {
                // Unknown or expensive syntax must never prevent plain-text editing.
                syntaxLogger.debug("Syntax coloring unavailable for this revision; using plain text.")
            }
        }
    }
}
