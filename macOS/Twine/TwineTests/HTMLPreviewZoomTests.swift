import AppKit
import SwiftUI
import Testing
import WebKit

@testable import Twine

@MainActor
struct HTMLPreviewZoomTests {
    @Test(arguments: [50, 100, 200])
    func webViewportFillsWindowAcrossZoomAndResize(initialPercent: Int) async throws {
        let temporary = TemporaryPath()
        try FileManager.default.createDirectory(at: temporary.url, withIntermediateDirectories: true)
        let file = temporary.url.appending(path: "viewport.html")
        try "<h1>Viewport</h1>".write(to: file, atomically: true, encoding: .utf8)
        let location = try #require(await HTMLPreviewLocation.resolve(file: file, folder: temporary.url))
        let suite = "com.twineproject.Twine.tests.HTMLPreviewZoomTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(initialPercent, forKey: "interfaceZoomPercent")
        let zoom = AppZoom(defaults: defaults)
        let hosting = NSHostingView(
            rootView: HTMLWebView(
                location: location, version: nil, isVisible: true, failure: .constant(nil), openFile: { _ in }
            ).appZoom().environment(\.appZoom, zoom))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<200 {
            if webView(in: hosting) != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        let view = try #require(webView(in: hosting))
        defer { view.stopLoading() }
        try await waitForLayout(view: view, hosting: hosting, scale: zoom.scale)
        for size in [CGSize(width: 600, height: 400), CGSize(width: 853, height: 517)] {
            window.setContentSize(size)
            zoom.reset()
            for _ in 0..<4 { zoom.zoomOut() }
            for _ in 0..<10 {
                try await waitForLayout(view: view, hosting: hosting, scale: zoom.scale)
                let physical = view.convert(view.bounds, to: hosting)
                #expect(abs(physical.width - size.width) < 2)
                #expect(abs(physical.height - size.height) < 2)
                #expect(abs(physical.minX) < 2 && abs(physical.minY) < 2)
                #expect(abs(view.bounds.width - size.width) < 2, "WebKit needs the physical viewport width")
                #expect(abs(view.bounds.height - size.height) < 2, "WebKit needs the physical viewport height")
                zoom.zoomIn()
            }
        }
    }

    private func webView(in root: NSView) -> WKWebView? {
        if let view = root as? WKWebView { return view }
        for child in root.subviews {
            if let view = webView(in: child) { return view }
        }
        return nil
    }

    private func waitForLayout(view: WKWebView, hosting: NSView, scale: CGFloat) async throws {
        for _ in 0..<200 {
            hosting.layoutSubtreeIfNeeded()
            // SwiftUI rounds the design frame before the host rounds its physical bounds.
            let fills =
                abs(view.bounds.width - hosting.bounds.width) < 2
                && abs(view.bounds.height - hosting.bounds.height) < 2
            if view.pageZoom == scale, fills {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record(
            "At \(scale): WebKit frame \(view.frame), bounds \(view.bounds), window \(hosting.bounds)")
        throw LayoutTimeout.viewport
    }

    private enum LayoutTimeout: Error { case viewport }
}
