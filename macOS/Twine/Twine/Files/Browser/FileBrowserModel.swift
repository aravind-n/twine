import Foundation
import OSLog
import Observation

private let filesLogger = Logger(subsystem: "com.twineproject.Twine", category: "files")

@Observable
final class FileBrowserModel {
    private(set) var isRootExpanded = true
    var expanded: Set<String> = []
    private(set) var snapshot: FileBrowserSnapshot?
    private(set) var failure: String?

    func request(folder: String, file: String? = nil) -> FileBrowserRequest {
        FileBrowserRequest(folder: folder, directories: expanded.sorted(), file: file)
    }

    func toggleRoot() {
        if isRootExpanded {
            collapseAll()
        } else {
            isRootExpanded = true
        }
    }

    func collapseAll() {
        isRootExpanded = false
        expanded.removeAll()
    }

    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded = expanded.filter { $0 != path && !$0.hasPrefix(path + "/") }
        } else if expanded.count < 256 {
            expanded.insert(path)
        } else {
            failure = "Collapse a folder before expanding another (256 folder limit)."
        }
    }

    func watch(_ request: FileBrowserRequest, client: CoreClient, editor: FileEditorModel?) async {
        var request = request
        var lastGeneration: UUID?
        do {
            while !Task.isCancelled {
                let generation = editor?.generation
                if generation != lastGeneration {
                    request.revision = nil
                    lastGeneration = generation
                }
                if let next = try await client.pollFiles(request) {
                    try Task.checkCancellation()
                    snapshot = next
                    if generation == editor?.generation { editor?.receive(next.file) }
                    request.revision = next.revision
                }
                failure = nil
                try await Task.sleep(for: .milliseconds(500))
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
            filesLogger.error("File browser refresh failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
