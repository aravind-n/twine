import Foundation
import Testing

@testable import Twine

@MainActor
struct TerminalChunkRouterTests {
    @Test func closedTerminalsDropOutputUntilStartedAgain() {
        var router = TerminalChunkRouter(capacityBytes: 64)
        router.markClosed(1)
        router.enqueue(chunk(terminalID: 1, bytes: "late"))
        #expect(router.dequeue(for: 1) == nil)

        router.markStarted(1)
        router.enqueue(chunk(terminalID: 1, bytes: "fresh"))
        #expect(router.dequeue(for: 1)?.bytes == Data("fresh".utf8))
    }

    @Test func removingEverythingForgetsClosedTerminals() {
        // The core numbers terminals from 1 again after it restarts.
        var router = TerminalChunkRouter(capacityBytes: 64)
        router.markClosed(1)
        router.removeAll()
        router.enqueue(chunk(terminalID: 1, bytes: "reconnected"))
        #expect(router.dequeue(for: 1)?.bytes == Data("reconnected".utf8))
    }

    @Test func closingATerminalFreesItsBufferedBytes() {
        var router = TerminalChunkRouter(capacityBytes: 4)
        router.enqueue(chunk(terminalID: 1, bytes: "full"))
        #expect(!router.hasCapacity)

        router.markClosed(1)
        #expect(router.hasCapacity)
    }

    private func chunk(terminalID: UInt64, bytes: String) -> CoreTerminalChunk {
        CoreTerminalChunk(terminalID: terminalID, offset: 0, bytes: Data(bytes.utf8))
    }
}
