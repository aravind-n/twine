import Foundation

/// WebKit's read scope and every local navigation use canonical paths, including symlink targets.
nonisolated struct HTMLPreviewLocation: Equatable, Sendable {
    let file: URL
    let folder: URL

    @concurrent static func resolve(file: URL, folder: URL) async -> Self? {
        guard file.isFileURL, folder.isFileURL,
            file.host == nil || file.host == "" || file.host == "localhost"
        else { return nil }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let target = file.resolvingSymlinksInPath().standardizedFileURL
        let rootParts = root.pathComponents
        let targetParts = target.pathComponents
        guard targetParts.count > rootParts.count, targetParts.starts(with: rootParts) else { return nil }
        guard let canonical = replacingPath(of: file, with: target.path) else { return nil }
        return Self(file: canonical, folder: root)
    }

    /// The core watches paths under the original opened folder, which may have symlinked ancestors.
    func fileURL(in openedFolder: String) -> URL? {
        let relative = file.pathComponents.dropFirst(folder.pathComponents.count).joined(separator: "/")
        return Self.replacingPath(of: file, with: URL(filePath: openedFolder).appending(path: relative).path)
    }

    private static func replacingPath(of url: URL, with path: String) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return nil }
        components.path = path
        return components.url
    }
}
