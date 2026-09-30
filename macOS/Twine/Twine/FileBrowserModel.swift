import Foundation
import OSLog
import Observation

private let filesLogger = Logger(subsystem: "com.twineproject.Twine", category: "files")

@Observable
final class FileBrowserModel {
    var expanded: Set<String> = []
    var selectedPath: String?
    private(set) var snapshot: FileBrowserSnapshot?
    private(set) var failure: String?

    func request(folder: String) -> FileBrowserRequest {
        FileBrowserRequest(folder: folder, directories: expanded.sorted(), file: selectedPath)
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

    func watch(_ request: FileBrowserRequest, client: BridgeClient) async {
        var request = request
        do {
            while !Task.isCancelled {
                if let next = try await client.pollFiles(request) {
                    try Task.checkCancellation()
                    snapshot = next
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
