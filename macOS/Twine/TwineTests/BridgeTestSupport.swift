import Foundation
import Testing

@testable import Twine

extension BridgeSnapshot {
    /// A ready snapshot with the default config and no folders or terminals.
    static func testReady(sequence: UInt64 = 1) -> Self {
        Self(
            sequence: sequence,
            state: BridgeApplicationState(status: .ready),
            config: BridgeConfig(appearance: .init(colorScheme: .system)),
            folders: BridgeFolderState(
                openFolder: nil,
                recentFolders: [],
                unavailableFolder: nil
            )
        )
    }
}

/// Checks `condition` every 10 ms for up to two seconds, and fails the test if it never holds.
@MainActor
func waitUntil(
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    for _ in 0..<200 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    let holds = await condition()
    try #require(holds, sourceLocation: sourceLocation)
}
