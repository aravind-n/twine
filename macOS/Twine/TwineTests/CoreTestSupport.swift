import Foundation
import Testing

@testable import Twine

extension CoreSnapshot {
    /// A ready snapshot with the default config and no folders or terminals.
    static func testReady(sequence: UInt64 = 1) -> Self {
        Self(
            sequence: sequence,
            state: CoreApplicationState(status: .ready),
            config: CoreConfig(appearance: .init(colorScheme: .system)),
            folders: CoreFolderState(
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

// Existing terminal-only doubles do not service trace reads. Trace tests supply their own reads.
extension CoreTransport {
    func workflowTrace(workflowID: UInt64, before: UInt64?, limit: UInt32) async throws -> CoreWorkflowTracePage {
        throw CoreFailure.unexpectedCommandResult
    }
    func traceEvents(spanID: UInt64, after: UInt64?, limit: UInt32) async throws -> CoreTraceEventsPage {
        throw CoreFailure.unexpectedCommandResult
    }
}
