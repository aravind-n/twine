import Foundation

/// A unique path under the temporary directory. Whatever a test creates there is deleted with the
/// path.
final class TemporaryPath {
    let url = URL.temporaryDirectory.appending(path: "TwineTests-\(UUID().uuidString)")

    var path: String { url.path(percentEncoded: false) }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
