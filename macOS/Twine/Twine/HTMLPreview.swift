import SwiftUI

struct HTMLPreview: View {
    let file: FilePreview
    let folder: String
    let navigationURL: URL?
    let openFile: (URL) -> Void
    @State private var load: Load?
    @State private var failure: String?

    var body: some View {
        ZStack {
            if let load {
                HTMLWebView(
                    location: load.location, version: load.version,
                    failure: $failure
                ) { destination in
                    if let url = destination.fileURL(in: folder) { openFile(url) }
                }
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
        .task(id: file) {
            let location = await HTMLPreviewLocation.resolve(
                file: navigationURL ?? URL(filePath: file.path), folder: URL(filePath: folder))
            guard !Task.isCancelled else { return }
            failure = nil
            if let location {
                load = Load(location: location, version: file.version)
            } else {
                load = nil
                failure = "Only files inside the opened folder can be previewed."
            }
        }
    }

    private struct Load {
        let location: HTMLPreviewLocation
        let version: FileVersion?
    }
}
