import Foundation

nonisolated enum MemoryExamples {
    static var root: String {
        if let override = ProcessInfo.processInfo.environment["TWINE_MEMORY_EXAMPLE_ROOT"] { return override }
        return DevelopmentPaths.checkoutDirectory
            .appending(path: "designs/memory-viewer-fixtures").path
    }
}
