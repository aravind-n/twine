import Foundation

nonisolated enum MarkdownPreviewURL {
    static let scheme = "twine-markdown"

    static func preview(_ file: URL) -> URL? {
        guard file.isFileURL, var components = URLComponents(url: file, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.scheme = scheme
        components.host = "preview"
        return components.url
    }

    static func file(_ preview: URL) -> URL? {
        guard preview.scheme == scheme, preview.host == "preview",
            var components = URLComponents(url: preview, resolvingAgainstBaseURL: true)
        else { return nil }
        components.scheme = "file"
        components.host = ""
        return components.url
    }
}
