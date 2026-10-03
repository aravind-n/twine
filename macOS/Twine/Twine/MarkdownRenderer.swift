import Darwin
import Foundation
import cmark_gfm
import cmark_gfm_extensions

nonisolated enum MarkdownRenderer {
    /// Parse away from the main actor; each render owns its parser and frees all C allocations.
    @concurrent static func render(_ source: String, baseURL: URL? = nil) async throws -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE | CMARK_OPT_VALIDATE_UTF8
        guard let parser = cmark_parser_new(options) else { throw RenderFailure.allocation }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            guard let syntax = cmark_find_syntax_extension(name),
                cmark_parser_attach_syntax_extension(parser, syntax) != 0
            else { throw RenderFailure.extensionUnavailable }
        }
        source.withCString { cmark_parser_feed(parser, $0, source.utf8.count) }
        guard let document = cmark_parser_finish(parser) else { throw RenderFailure.allocation }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, options, cmark_parser_get_syntax_extensions(parser)) else {
            throw RenderFailure.allocation
        }
        defer { free(html) }
        return page(body: String(cString: html), baseURL: baseURL)
    }

    private static func page(body: String, baseURL: URL?) -> String {
        let escapedURL = (baseURL?.absoluteString ?? "")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
            <!doctype html>
            <html><head><meta charset="utf-8">
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
            </style></head><body><main>\(body)</main></body></html>
            """
    }

    private enum RenderFailure: LocalizedError {
        case allocation, extensionUnavailable

        var errorDescription: String? { "The Markdown couldn't be rendered. Switch to Source to inspect the file." }
    }
}
