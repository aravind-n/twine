import Foundation

nonisolated enum FilePreviewFormat: Sendable {
    case html, markdown

    init?(path: String) {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "html", "htm": self = .html
        case "md", "markdown": self = .markdown
        default: return nil
        }
    }

    var name: String { self == .html ? "HTML" : "Markdown" }
    var accessibilityPrefix: String { self == .html ? "html" : "markdown" }
}
