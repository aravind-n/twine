import SwiftUI

struct HTMLPreview: View {
    let file: FilePreview
    let folder: String
    let navigationURL: URL?
    let isVisible: Bool
    let openFile: (URL) -> Void
    var format: FilePreviewFormat = .html
    @State private var load: Load?
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let load {
                HTMLWebView(
                    location: load.location, version: load.version,
                    isVisible: isVisible, failure: $failure,
                    openFile: { destination in
                        if let url = destination.fileURL(in: folder) { openFile(url) }
                    }, format: format, html: load.html)
            }
            if let failure {
                ContentUnavailableView(
                    "Preview Unavailable", systemImage: "globe",
                    description: Text(failure)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            } else if load == nil {
                ProgressView("Loading preview…")
            }
        }
        .task(id: Request(file: file, navigationURL: navigationURL)) {
            let location = await HTMLPreviewLocation.resolve(
                file: navigationURL ?? URL(filePath: file.path), folder: URL(filePath: folder))
            guard !Task.isCancelled else { return }
            failure = nil
            if let location {
                do {
                    let html: String?
                    if format == .markdown {
                        html = try await MarkdownRenderer.render(
                            file.text ?? "", baseURL: MarkdownPreviewURL.preview(location.file))
                    } else {
                        html = nil
                    }
                    guard !Task.isCancelled else { return }
                    load = Load(location: location, version: file.version, html: html)
                } catch {
                    guard !Task.isCancelled else { return }
                    load = nil
                    failure = error.localizedDescription
                }
            } else {
                load = nil
                failure = "Only files inside the opened folder can be previewed."
            }
        }
    }

    private struct Load {
        let location: HTMLPreviewLocation
        let version: FileVersion?
        let html: String?
    }

    private struct Request: Equatable {
        let file: FilePreview
        let navigationURL: URL?
    }
}
