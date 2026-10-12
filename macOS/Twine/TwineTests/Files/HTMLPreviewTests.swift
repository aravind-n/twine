import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Twine

@MainActor
struct HTMLPreviewTests {
    @Test func localScopeResolvesTraversalAndSymlinks() async throws {
        let temporary = TemporaryPath()
        let root = temporary.url.appending(path: "site")
        let sibling = temporary.url.appending(path: "site-other")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let inside = root.appending(path: "a page.html")
        let outside = sibling.appending(path: "secret.html")
        try "inside".write(to: inside, atomically: true, encoding: .utf8)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        let escape = root.appending(path: "escape")
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: sibling)
        let fileEscape = root.appending(path: "escape.html")
        try FileManager.default.createSymbolicLink(at: fileEscape, withDestinationURL: outside)
        let alias = temporary.url.appending(path: "alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)

        #expect(await HTMLPreviewLocation.resolve(file: inside, folder: root) != nil)
        let aliased = try #require(
            await HTMLPreviewLocation.resolve(file: alias.appending(path: "a page.html"), folder: alias))
        #expect(aliased.fileURL(in: alias.path)?.path == alias.appending(path: "a page.html").path)
        for denied in [
            outside, escape.appending(path: "secret.html"), fileEscape, root,
            root.appending(path: "../site-other/secret.html"),
        ] {
            #expect(await HTMLPreviewLocation.resolve(file: denied, folder: root) == nil)
        }
        let remoteFile = try #require(
            URL(string: "file://remotehost\(inside.path)".replacingOccurrences(of: " ", with: "%20")))
        #expect(await HTMLPreviewLocation.resolve(file: remoteFile, folder: root) == nil)
        let web = try #require(URL(string: "https://example.com"))
        #expect(await HTMLPreviewLocation.resolve(file: web, folder: root) == nil)
    }

    private func makeSite(in root: URL) throws -> URL {
        let outside = root.deletingLastPathComponent().appending(path: "outside.html")
        try "<h1>Outside</h1>".write(to: outside, atomically: true, encoding: .utf8)
        let file = root.appending(path: "index.html")
        try """
        <html><head><link rel="stylesheet" href="style.css"></head><body>
        <p id="content">Local preview</p><img id="image" src="image.svg">
        <a id="local" href="next.htm?mode=example#section">Next</a>
        <a id="external" href="https://example.com/">External</a>
        <a id="blank" href="https://example.com/new" target="_blank">New window</a>
        <a id="outside" href="../outside.html">Outside</a>
        <a id="symlink" href="escape.html">Symlink</a>
        <script src="script.js"></script></body></html>
        """.write(to: file, atomically: true, encoding: .utf8)
        try "#content { color: rgb(12, 34, 56); }".write(
            to: root.appending(path: "style.css"), atomically: true, encoding: .utf8)
        try "document.body.dataset.script = 'loaded';".write(
            to: root.appending(path: "script.js"), atomically: true, encoding: .utf8)
        try "<svg xmlns='http://www.w3.org/2000/svg' width='17' height='19'><rect width='17' height='19'/></svg>".write(
            to: root.appending(path: "image.svg"), atomically: true, encoding: .utf8)
        try "<h1>Next</h1>".write(to: root.appending(path: "next.htm"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape.html"), withDestinationURL: outside)
        return file
    }

    @Test func webKitRendersSiblingAssetsAndRoutesNavigation() async throws {
        let temporary = TemporaryPath()
        let root = temporary.url.appending(path: "site")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = try makeSite(in: root)
        let location = try #require(await HTMLPreviewLocation.resolve(file: file, folder: root))
        var external: [URL] = []
        var selected: [URL] = []
        var failure: String?
        let coordinator = HTMLWebView.Coordinator(
            location: location, failure: Binding(get: { failure }, set: { failure = $0 }),
            openFile: { selected.append($0.file) },
            openExternal: {
                external.append($0)
                return true
            })
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        view.navigationDelegate = coordinator
        coordinator.loadNavigation = view.loadFileURL(location.file, allowingReadAccessTo: location.folder)
        defer { view.stopLoading() }
        try await waitUntil {
            try await view.evaluateJavaScript("document.body?.dataset.script === 'loaded' && image.complete") as? Bool
                == true
        }
        #expect(try await view.evaluateJavaScript("getComputedStyle(content).color") as? String == "rgb(12, 34, 56)")
        #expect(try await view.evaluateJavaScript("image.naturalWidth") as? Int == 17)
        #expect(failure == nil, "Initial load")
        for link in ["external", "blank"] {
            _ = try await view.evaluateJavaScript("document.getElementById('\(link)').click()")
        }
        try await waitUntil { external.count == 2 }
        #expect(external.map(\.absoluteString) == ["https://example.com/", "https://example.com/new"])
        #expect(failure == nil, "External links")
        for link in ["outside", "symlink"] {
            _ = try await view.evaluateJavaScript("document.getElementById('\(link)').click()")
            try await Task.sleep(for: .milliseconds(100))
            #expect(view.url?.path == location.file.path)
            #expect(selected.isEmpty)
            #expect(failure == nil, "Blocked \(link)")
        }
        try await verifyHiddenNavigation(view: view, coordinator: coordinator, selected: { selected })
        _ = try await view.evaluateJavaScript("document.getElementById('local').click()")
        try await waitUntil { selected.count == 1 }
        #expect(selected.first?.lastPathComponent == "next.htm")
        #expect(selected.first?.query == "mode=example")
        #expect(selected.first?.fragment == "section")
        #expect(failure == nil)
    }

    private func verifyHiddenNavigation(
        view: WKWebView, coordinator: HTMLWebView.Coordinator, selected: () -> [URL]
    ) async throws {
        coordinator.isVisible = false
        defer { coordinator.isVisible = true }
        _ = try await view.evaluateJavaScript("location.href = document.getElementById('local').href")
        try await Task.sleep(for: .milliseconds(200))
        #expect(selected().isEmpty, "A hidden page must not switch the active tab")
        #expect(view.url?.path == coordinator.location.file.path)
    }

    private func waitUntil(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for WebKit")
    }
}
