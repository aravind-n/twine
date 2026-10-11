import Darwin
import Foundation
import cmark_gfm
import cmark_gfm_extensions

nonisolated enum MarkdownRenderer {
    enum Style: Sendable { case document, memory }
    /// Parse away from the main actor; each render owns its parser and frees all C allocations.
    @concurrent static func render(
        _ source: String, baseURL: URL? = nil, localResourcesOnly: Bool = false, style: Style = .document
    ) async throws -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { throw RenderFailure.allocation }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            guard let syntax = cmark_find_syntax_extension(name),
                cmark_parser_attach_syntax_extension(parser, syntax) != 0
            else { throw RenderFailure.extensionUnavailable }
        }
        let markdown = style == .memory ? withoutFrontmatter(source) : source
        markdown.withCString { cmark_parser_feed(parser, $0, markdown.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { throw RenderFailure.allocation }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            throw RenderFailure.allocation
        }
        defer { free(html) }
        return page(body: String(cString: html), baseURL: baseURL, localResourcesOnly: localResourcesOnly, style: style)
    }

    private static func page(body: String, baseURL: URL?, localResourcesOnly: Bool, style: Style) -> String {
        let resourcePolicy =
            localResourcesOnly
            ? "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; "
                + "img-src twine-markdown: data:; style-src 'unsafe-inline';\">"
            : ""
        let escapedURL = (baseURL?.absoluteString ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
            \(resourcePolicy)
            <base href="\(escapedURL)">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="color-scheme" content="light dark">
            <style>
            :root { color-scheme: light dark; }
            body {
                margin: 0; padding: 24px; color: CanvasText; background: Canvas;
                font: 14px/1.6 -apple-system, BlinkMacSystemFont, sans-serif;
                overflow-wrap: anywhere;
            }
            main { max-width: 880px; margin: 0 auto; }
            h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.4em 0 .6em; }
            main > :first-child { margin-top: 0; }
            h1, h2 { padding-bottom: .3em; border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); }
            a { color: LinkText; }
            img { max-width: 100%; height: auto; }
            code, pre { font-family: ui-monospace, SFMono-Regular, monospace; font-size: 12.5px; }
            code { padding: .15em .35em; border-radius: 4px; background: color-mix(in srgb, CanvasText 6%, Canvas); }
            pre { padding: 14px; border-radius: 8px; overflow-x: auto;
                  background: color-mix(in srgb, CanvasText 6%, Canvas); }
            pre code { padding: 0; background: none; overflow-wrap: normal; }
            blockquote { margin: 1em 0; padding: 0 1em; border-left: 3px solid GrayText; color: GrayText; }
            table { display: block; max-width: 100%; overflow-x: auto; border-collapse: collapse; }
            th, td { padding: 6px 12px; border: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); }
            tr:nth-child(even) { background: color-mix(in srgb, CanvasText 4%, Canvas); }
            hr { border: 0; border-top: 1px solid color-mix(in srgb, CanvasText 15%, Canvas); }
            input[type="checkbox"] { margin-right: .5em; }
            \(style == .memory ? memoryStyle : "")
            </style></head><body><main>\(body)</main></body></html>
            """
    }

    private static let memoryStyle = """
        body { padding: 18px; font-size: 13px; line-height: 1.8; background: #faf9f5; color: #28302f; }
        main { max-width: none; }
        h1 { font-size: 18px; border: 0; padding: 0; }
        h2 { font-size: 15px; border: 0; padding: 0; }
        h3, h4, h5, h6 { font-size: 14px; }
        p { margin: .6em 0; }
        a { color: #4b6f9e; }
        @media (prefers-color-scheme: dark) {
            body { background: #272b2d; color: #e5e6df; }
            a { color: #93b5e4; }
        }
        """

    private static func withoutFrontmatter(_ source: String) -> String {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
            let end = lines.dropFirst().firstIndex(where: {
                ["---", "..."].contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
            })
        else { return source }
        return lines.dropFirst(end + 1).joined(separator: "\n")
    }

    private enum RenderFailure: LocalizedError {
        case allocation, extensionUnavailable

        var errorDescription: String? { "The Markdown couldn't be rendered. Switch to Source to inspect the file." }
    }
}
