import Foundation
import SwiftUI
import Testing
import WebKit

@testable import Twine

@MainActor
struct MarkdownPreviewTests {
    @Test func memoryRenderingHidesFrontmatterAndRestrictsRemoteResources() async throws {
        let source = "---\nname: hidden metadata\n---\n# Readable memory\n\n**Useful** advice.\n"
        let html = try await MarkdownRenderer.render(source, localResourcesOnly: true, style: .memory)
        #expect(html.contains("<h1>Readable memory</h1>"))
        #expect(html.contains("<strong>Useful</strong>"))
        #expect(!html.contains("hidden metadata"))
        #expect(html.contains("default-src 'none'"))
        #expect(html.contains("img-src twine-markdown: data:"))
        #expect(try await MarkdownRenderer.render(source).contains("hidden metadata"))
        #expect(try await MarkdownRenderer.render("---\nunclosed", style: .memory).contains("unclosed"))
    }

    @Test func rendersBlocksInlineFormattingAndGitHubExtensions() async throws {
        let html = try await MarkdownRenderer.render(
            """
            # Heading 🌲

            **Bold** and *emphasis* with `code` and ~~removed~~.

            > A quote

            1. First
            2. Second
               - Nested

            - [x] Done
            - [ ] Pending

            | Name | Value |
            | --- | --- |
            | Item | 42 |

            ```swift
            let value = "<tag> & text"
            ```

            [Local](next.md#section) and https://example.com

            ![Diagram](images/diagram.svg)
            """)
        for expected in [
            "<h1>Heading 🌲</h1>", "<strong>Bold</strong>", "<em>emphasis</em>", "<code>code</code>",
            "<del>removed</del>", "<blockquote>", "<ol>", "<ul>", "<li>Nested</li>",
            "type=\"checkbox\"", "checked=\"\"", "<table>", "<th>Name</th>", "<td>42</td>",
            "class=\"language-swift\"", "&lt;tag&gt; &amp; text", "href=\"next.md#section\"",
            "href=\"https://example.com\"", "src=\"images/diagram.svg\"", "alt=\"Diagram\"",
        ] {
            #expect(html.contains(expected), "Missing rendered syntax: \(expected)")
        }
    }

    @Test func emptyDocumentsAndConcurrentRendersRemainIndependent() async throws {
        #expect(try await MarkdownRenderer.render("").contains("<main></main>"))
        let pages = try await withThrowingTaskGroup(of: String.self) { group in
            for index in 0..<12 {
                group.addTask { try await MarkdownRenderer.render("# Document \(index)\n\n- [x] Done") }
            }
            var pages: [String] = []
            for try await page in group { pages.append(page) }
            return pages
        }
        #expect(pages.count == 12)
        for index in 0..<12 {
            #expect(pages.filter { $0.contains("<h1>Document \(index)</h1>") }.count == 1)
        }
    }
    @Test func webKitRendersRelativeImagesAndRoutesLocalAndExternalLinks() async throws {
        let temporary = TemporaryPath()
        let root = temporary.url.appending(path: "docs")
        let (file, source) = try makeDocument(in: root)
        let location = try #require(await HTMLPreviewLocation.resolve(file: file, folder: root))
        var selected: [URL] = []
        var external: [URL] = []
        var failure: String?
        let coordinator = HTMLWebView.Coordinator(
            location: location, failure: Binding(get: { failure }, set: { failure = $0 }),
            openFile: { selected.append($0.file) },
            openExternal: {
                external.append($0)
                return true
            })
        let configuration = HTMLWebView.configuration(for: .markdown, location: location)
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: configuration)
        view.navigationDelegate = coordinator
        let html = try await MarkdownRenderer.render(source, baseURL: MarkdownPreviewURL.preview(location.file))
        coordinator.loadGenerated(html, in: view)
        defer {
            view.stopLoading()
            coordinator.stop()
        }
        try await waitUntil("document content") {
            try await view.evaluateJavaScript("document.querySelector('h1')?.textContent === 'Markdown preview'")
                as? Bool
                == true
        }
        try await waitUntil("relative image") {
            try await view.evaluateJavaScript("document.querySelector('img')?.naturalWidth === 17") as? Bool == true
        }
        try await verifyAnchors(in: view)
        _ = try await view.evaluateJavaScript("document.querySelector('a[href^=\"https:\"]').click()")
        try await waitUntil { external.count == 1 }
        #expect(external.first?.absoluteString == "https://example.com/")
        _ = try await view.evaluateJavaScript("document.querySelector('a[href^=\"../\"]').click()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(selected.isEmpty)
        coordinator.isVisible = false
        _ = try await view.evaluateJavaScript("document.querySelector('a[href^=\"next\"]').click()")
        try await Task.sleep(for: .milliseconds(100))
        #expect(selected.isEmpty)
        coordinator.isVisible = true
        _ = try await view.evaluateJavaScript("document.querySelector('a[href^=\"next\"]').click()")
        try await waitUntil { selected.count == 1 }
        #expect(selected.first?.lastPathComponent == "next.MARKDOWN")
        #expect(selected.first?.query == "mode=example")
        #expect(selected.first?.fragment == "section")
        #expect(failure == nil)
    }

    @Test func linkedDocumentScrollsToItsInitialHeadingFragment() async throws {
        let temporary = TemporaryPath()
        let root = temporary.url.appending(path: "site")
        let (file, source) = try makeDocument(in: root)
        var components = try #require(URLComponents(url: file, resolvingAgainstBaseURL: false))
        components.fragment = "section-1"
        let url = try #require(components.url)
        let location = try #require(await HTMLPreviewLocation.resolve(file: url, folder: root))
        var failure: String?
        let coordinator = HTMLWebView.Coordinator(
            location: location, failure: Binding(get: { failure }, set: { failure = $0 }),
            openFile: { _ in Issue.record("An initial anchor must stay in its preview") })
        let view = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 600, height: 400),
            configuration: HTMLWebView.configuration(for: .markdown, location: location))
        view.navigationDelegate = coordinator
        let html = try await MarkdownRenderer.render(source, baseURL: MarkdownPreviewURL.preview(location.file))
        coordinator.loadGenerated(html, in: view)
        defer {
            view.stopLoading()
            coordinator.stop()
        }
        try await waitUntil("initial fragment") {
            try await view.evaluateJavaScript("window.scrollY > 0") as? Bool == true
        }
        #expect(try await view.evaluateJavaScript("document.querySelectorAll('h2')[1].id") as? String == "section-1")
        #expect(failure == nil)
    }

    private func makeDocument(in root: URL) throws -> (URL, String) {
        let docs = root.appending(path: "docs")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let file = docs.appending(path: "read me.md")
        let source = """
            # Markdown preview

            ![Diagram](../image.svg)

            [Next](next.MARKDOWN?mode=example#section)
            [External](https://example.com/)
            [Outside](../../outside.md)

            [Fragment](#section)
            [Same file](read%20me.md#section)

            <div style="height: 800px"></div>

            ## Section

            ## Section
            """
        try source.write(to: file, atomically: true, encoding: .utf8)
        try "# Next".write(to: docs.appending(path: "next.MARKDOWN"), atomically: true, encoding: .utf8)
        try "<svg xmlns='http://www.w3.org/2000/svg' width='17' height='19'><rect width='17' height='19'/></svg>".write(
            to: root.appending(path: "image.svg"), atomically: true, encoding: .utf8)
        let outside = root.deletingLastPathComponent().appending(path: "outside.svg")
        try FileManager.default.copyItem(at: root.appending(path: "image.svg"), to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "escape.svg"), withDestinationURL: outside)
        return (file, source)
    }

    @Test func assetsRejectTraversalSymlinksAndOversizedFiles() async throws {
        let temporary = TemporaryPath()
        let root = temporary.url.appending(path: "site")
        _ = try makeDocument(in: root)
        let large = root.appending(path: "large.bin")
        try Data().write(to: large)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 64 * 1024 * 1024 + 1)
        try handle.close()
        for file in [root.appending(path: "../outside.svg"), root.appending(path: "escape.svg"), large] {
            let url = try #require(MarkdownPreviewURL.preview(file))
            await #expect(throws: URLError.self) {
                _ = try await MarkdownAssetHandler.read(url: url, folder: root)
            }
        }
    }

    private func verifyAnchors(in view: WKWebView) async throws {
        #expect(
            try await view.evaluateJavaScript("Array.from(document.querySelectorAll('h2'), h => h.id)") as? [String]
                == ["section", "section-1"])
        for title in ["Fragment", "Same file"] {
            _ = try await view.evaluateJavaScript("window.scrollTo(0, 0)")
            _ = try await view.callAsyncJavaScript(
                "Array.from(document.querySelectorAll('a')).find(a => a.textContent === title).click()",
                arguments: ["title": title], in: nil, contentWorld: .page)
            try await waitUntil { try await view.evaluateJavaScript("window.scrollY > 0") as? Bool == true }
            #expect(
                try await view.evaluateJavaScript("document.querySelector('h1')?.textContent") as? String
                    == "Markdown preview")
        }
    }

    private func waitUntil(_ detail: String = "navigation", _ condition: () async throws -> Bool) async throws {
        for _ in 0..<200 {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw PreviewTimeout.waitingForWebKit(detail)
    }

    private enum PreviewTimeout: Error { case waitingForWebKit(String) }
}
