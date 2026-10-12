import Foundation
import OSLog
import UniformTypeIdentifiers
import WebKit

private nonisolated let markdownAssetLogger = Logger(subsystem: "com.twineproject.Twine", category: "markdown-assets")

/// Serves preview resources through WebKit's custom scheme, within the same canonical folder scope as HTML.
final class MarkdownAssetHandler: NSObject, WKURLSchemeHandler {
    let folder: URL
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(folder: URL) { self.folder = folder }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        tasks[id] = Task {
            do {
                let asset = try await Self.read(url: url, folder: folder)
                guard !Task.isCancelled, tasks[id] != nil else { return }
                urlSchemeTask.didReceive(
                    URLResponse(
                        url: url, mimeType: asset.mimeType, expectedContentLength: asset.data.count,
                        textEncodingName: nil))
                urlSchemeTask.didReceive(asset.data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, tasks[id] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
            tasks[id] = nil
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    @concurrent static func read(url: URL, folder: URL) async throws -> Asset {
        guard let file = MarkdownPreviewURL.file(url),
            let location = await HTMLPreviewLocation.resolve(file: file, folder: folder)
        else { throw URLError(.noPermissionsToReadFile) }
        let values = try location.file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw URLError(.fileIsDirectory)
        }
        let limit = 64 * 1024 * 1024
        guard let size = values.fileSize, size >= 0, size <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: location.file)
        defer {
            do {
                try handle.close()
            } catch {
                markdownAssetLogger.error("Asset close failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        let data = try handle.read(upToCount: size + 1) ?? Data()
        guard data.count <= size else { throw URLError(.resourceUnavailable) }
        let mimeType =
            UTType(filenameExtension: location.file.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        return Asset(data: data, mimeType: mimeType)
    }

    nonisolated struct Asset: Sendable {
        let data: Data
        let mimeType: String
    }
}
