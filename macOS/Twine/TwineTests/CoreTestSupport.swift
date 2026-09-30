import Foundation
import Testing

/// Checks `condition` every 10 ms until the elapsed-time deadline, then fails if it never holds.
@MainActor
func waitUntil(
    _ condition: () async -> Bool,
    timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    repeat {
        if await condition() { return }
        try await clock.sleep(for: .milliseconds(10))
    } while clock.now < deadline
    let holds = await condition()
    try #require(holds, sourceLocation: sourceLocation)
}
