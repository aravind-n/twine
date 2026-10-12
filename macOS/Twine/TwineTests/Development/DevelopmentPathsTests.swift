import Foundation
import Testing

@testable import Twine

struct DevelopmentPathsTests {
    @Test(arguments: [
        "AppPaths.swift",
        "Development/AppPaths.swift",
        "Development/Previews/Nested/Example.swift",
        "Memories/MemoryExamples.swift",
    ])
    func sourceRelocationPreservesCheckout(source: String) throws {
        let checkout = URL(filePath: "/tmp/Twine/checkouts/Twine app", directoryHint: .isDirectory)
        let file = checkout.appending(path: "macOS/Twine/Twine/\(source)")
        let resolved = try #require(DevelopmentPaths.checkoutDirectory(containing: file.path))
        #expect(resolved == checkout)
    }

    @Test func unrelatedSourcePathsHaveNoCheckout() {
        #expect(DevelopmentPaths.checkoutDirectory(containing: "/tmp/Twine/Development/AppPaths.swift") == nil)
        #expect(DevelopmentPaths.checkoutDirectory(containing: "/tmp/macOS/Twine/Other/AppPaths.swift") == nil)
    }

    @Test func buildCheckoutContainsRepositoryResources() {
        let checkout = DevelopmentPaths.checkoutDirectory
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "Makefile").path))
        #expect(FileManager.default.fileExists(atPath: checkout.appending(path: "macOS/Twine/Twine.xcodeproj").path))
    }

    @MainActor
    @Test func developmentConsumersKeepTheirPathsAndOverrides() {
        let checkout = DevelopmentPaths.checkoutDirectory
        #expect(AppPaths.previewDirectory.path == checkout.appending(path: "out/runtime/debug/previews").path)
        let environment = ProcessInfo.processInfo.environment
        let examples =
            environment["TWINE_MEMORY_EXAMPLE_ROOT"]
            ?? checkout.appending(path: "designs/memory-viewer-fixtures").path
        #expect(MemoryExamples.root == examples)
        if let override = environment["TWINE_DATA_DIRECTORY"] {
            #expect(AppPaths.dataDirectory == URL(filePath: override, directoryHint: .isDirectory))
        } else {
            #if DEBUG
                #expect(AppPaths.dataDirectory.path == checkout.appending(path: "out/runtime/debug").path)
            #else
                #expect(AppPaths.dataDirectory == URL.applicationSupportDirectory.appending(path: "Twine"))
            #endif
        }
    }
}
