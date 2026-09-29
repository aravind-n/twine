import Foundation
import SwiftUI
import Testing

@testable import Twine

struct TerminalControllerTests {
    @Test @MainActor func inputTypedBeforeTheShellStartsIsSentOnceItHas() async throws {
        let transport = DelayedStartTransport()
        let client = BridgeClient(transport: transport)
        client.start()
        defer { Task { await client.stop() } }
        let controller = TerminalController(
            bridgeClient: client,
            workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil),
            failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { controller.stop() }

        controller.start(view: view)
        try await waitUntil { await transport.hasStartRequest }

        controller.send(source: view, data: Array("ls\r".utf8)[...])
        await transport.completeStart(terminalID: 1)

        try await waitUntil { await transport.input == Data("ls\r".utf8) }
    }

    @Test @MainActor func terminalAppliesResizeReceivedDuringStartup() async throws {
        let transport = DelayedStartTransport()
        let client = BridgeClient(transport: transport)
        client.start()
        try await waitUntil { client.connectionState == .running }

        var boundTerminalID: UInt64?
        var failureMessage: String?
        let controller = TerminalController(
            bridgeClient: client,
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            terminalID: Binding(
                get: { boundTerminalID },
                set: { boundTerminalID = $0 }
            ),
            failureMessage: Binding(
                get: { failureMessage },
                set: { failureMessage = $0 }
            )
        )
        let terminal = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        controller.start(view: terminal)
        try await waitUntil { await transport.hasStartRequest }

        controller.sizeChanged(source: terminal, newCols: 120, newRows: 40)
        await transport.completeStart(terminalID: 41)
        try await waitUntil { await transport.lastResize != nil }

        let resize = try #require(await transport.lastResize)
        #expect(resize.columns == 120)
        #expect(resize.rows == 40)
        #expect(boundTerminalID == 41)
        #expect(failureMessage == nil)

        controller.stop()
        try await Task.sleep(for: .milliseconds(20))
        await client.stop()
    }

    @Test @MainActor func shellWaitsForTheBridgeConnection() async throws {
        let transport = DelayedStartTransport()
        let client = BridgeClient(transport: transport)
        defer { Task { await client.stop() } }
        let controller = TerminalController(
            bridgeClient: client,
            workingDirectory: URL(filePath: "/"),
            terminalID: .constant(nil),
            failureMessage: .constant(nil)
        )
        let view = MetalTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        defer { controller.stop() }

        controller.start(view: view)
        try await Task.sleep(for: .milliseconds(50))
        #expect(client.connectionState == .idle)
        #expect(await !transport.hasStartRequest)

        client.start()
        try await waitUntil { await transport.hasStartRequest }
    }
}
