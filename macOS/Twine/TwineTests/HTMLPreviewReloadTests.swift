import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Twine

@MainActor
struct HTMLPreviewReloadTests {
    @Test(arguments: [false, true])
    func reusedPreviewReloadsContentAndMemoryRenderingOptions(memoryContext: Bool) async throws {
        let temporary = TemporaryPath()
        try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
        let path = temporary.url.appending(path: "memory.md").path
        func preview(_ text: String, memory: Bool = false) -> HTMLPreview {
            HTMLPreview(
                file: .init(path: path, status: .text, text: text, message: nil, version: nil),
                folder: temporary.url.path, navigationURL: nil, isVisible: false, openFile: { _ in },
                format: .markdown, localResourcesOnly: memory, hidesFrontmatter: memory, focusesOnShow: false)
        }
        let original = "---\nname: hidden metadata\n---\n# Original record"
        let hosting = NSHostingView(rootView: preview(original))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        try await waitUntil("hosted preview") {
            hosting.layoutSubtreeIfNeeded()
            return webView(in: hosting) != nil
        }
        let view = try #require(webView(in: hosting))
        defer { view.stopLoading() }
        try await waitUntil("original record") {
            try await view.evaluateJavaScript("document.querySelector('h1')?.textContent === 'Original record'")
                as? Bool == true
        }
        #expect(
            try await view.evaluateJavaScript("document.body.textContent.includes('hidden metadata')") as? Bool == true)
        if memoryContext {
            hosting.rootView = preview(original, memory: true)
            try await waitUntil("memory rendering policy") {
                try await view.evaluateJavaScript(
                    "!document.body.textContent.includes('hidden metadata') && "
                        + "document.querySelector('meta[http-equiv=\"Content-Security-Policy\"]')"
                        + "?.content.includes(\"default-src 'none'\")"
                )
                    as? Bool == true
            }
        } else {
            hosting.rootView = preview("# Refreshed record")
            try await waitUntil("refreshed record without a writable version") {
                try await view.evaluateJavaScript("document.querySelector('h1')?.textContent === 'Refreshed record'")
                    as? Bool == true
            }
        }
        #expect(webView(in: hosting) === view)
    }

    private func webView(in root: NSView) -> WKWebView? {
        if let view = root as? WKWebView { return view }
        for child in root.subviews {
            if let view = webView(in: child) { return view }
        }
        return nil
    }

    private func waitUntil(_ detail: String, _ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PreviewTimeout.waitingForWebKit(detail)
    }

    private enum PreviewTimeout: Error { case waitingForWebKit(String) }
}
