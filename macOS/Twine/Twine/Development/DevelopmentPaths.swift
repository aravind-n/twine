import Foundation

nonisolated enum DevelopmentPaths {
    static let checkoutDirectory: URL = {
        guard let directory = checkoutDirectory(containing: #filePath) else {
            preconditionFailure("Development sources must be inside macOS/Twine/Twine")
        }
        return directory
    }()

    static func checkoutDirectory(containing sourceFile: String) -> URL? {
        var directory = URL(filePath: sourceFile).deletingLastPathComponent()
        while directory.path != "/" {
            if directory.pathComponents.suffix(3) == ["macOS", "Twine", "Twine"] {
                return directory.deletingLastPathComponent().deletingLastPathComponent()
                    .deletingLastPathComponent()
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }
}
