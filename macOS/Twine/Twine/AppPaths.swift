import Foundation

/// Separate development state from the installed app, including launches outside the Makefile.
enum AppPaths {
    static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TWINE_DATA_DIRECTORY"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        #if DEBUG
            return developmentDirectory
        #else
            return .applicationSupportDirectory.appending(path: "Twine", directoryHint: .isDirectory)
        #endif
    }

    static var previewDirectory: URL {
        developmentDirectory.appending(path: "previews", directoryHint: .isDirectory)
    }

    private static var developmentDirectory: URL {
        // Bind developer state to the checkout that built the app, including previews and test hosts.
        return URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "out/runtime/debug")
    }
}
