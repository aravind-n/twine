import AppKit
import Foundation
import SwiftUI
import Testing

@testable import Twine

@MainActor
struct MultiAgentWorkflowTests {
    @Test func workflowsDecodeAgentsAndShowSubtabsOnlyForMoreThanOne() throws {
        let json = """
            {"workflowId": 3, "sessionId": 1, "name": "Agents", "kind": "agents", "terminalId": 0,
             "agents": [{"agentId": 5, "role": "Implementer", "terminalId": 8},
                        {"agentId": 6, "role": "Reviewer", "terminalId": 0}],
             "status": "running", "startedAt": 10, "endedAt": null, "restored": true}
            """
        var workflow = try JSONDecoder().decode(BridgeWorkflow.self, from: Data(json.utf8))
        #expect(workflow.kind == .agents)
        #expect(
            workflow.agents == [
                BridgeAgent(agentID: 5, role: "Implementer", terminalID: 8),
                BridgeAgent(agentID: 6, role: "Reviewer", terminalID: 0),
            ])
        #expect(workflow.terminalIDs == [8])
        #expect(workflow.showsAgentSubtabs)
        workflow.agents.removeLast()
        #expect(!workflow.showsAgentSubtabs)
        workflow.agents.removeAll()
        #expect(!workflow.showsAgentSubtabs)
    }

    @Test func roleStylesAreStableAndMatchTheDesign() {
        #expect(RoleStyle(role: "implementer") == RoleStyle(role: "Implementer"))
        #expect(RoleStyle(role: "Implementer").color == .roleBlue)
        #expect(RoleStyle(role: "Reviewer").color == .roleOrange)
        #expect(RoleStyle(role: "Coordinator").color == .rolePurple)
        #expect(RoleStyle(role: "Worker").color == .roleGreen)
        #expect(RoleStyle(role: "Worker 2") == RoleStyle(role: "Worker"))
        // Other roles stay neutral rather than borrow a built-in role's color.
        #expect(RoleStyle(role: "Tester") == RoleStyle(role: "Designer"))
        #expect(RoleStyle(role: "Tester").color == .secondary)
        let symbols = ["Implementer", "Reviewer", "Coordinator", "Worker", "Tester"].map { RoleStyle(role: $0).symbol }
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains("arrow.triangle.branch"), "The footer's Git branch uses that symbol")
        for symbol in symbols {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol)")
        }
    }

    @Test func createWorkflowSendsRolesOnlyWhenThereAreSome() throws {
        let size = BridgeTerminalSize(rows: 24, columns: 80, pixelWidth: 800, pixelHeight: 480)
        func payload(_ command: BridgeCommand) throws -> [String: Any] {
            let data = try JSONEncoder().encode(CommandEnvelope(requestID: 1, command: command))
            let envelope = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try #require(envelope["command"] as? [String: Any])
        }
        let agents = try payload(.createWorkflow(folder: "/f", kind: .agents, roles: ["Implementer"], size: size))
        #expect(agents["kind"] as? String == "agents")
        #expect(agents["roles"] as? [String] == ["Implementer"])
        #expect(try payload(.createWorkflow(folder: "/f", kind: .terminal, size: size))["roles"] == nil)
    }

    @Test func agentsRunTheirOwnShellsAndTheWorkflowEndsWithTheLastOne() async throws {
        let (client, directory) = try await openFolder()
        let folder = directory.path
        do {
            let roles = ["Implementer", "Reviewer", "Coordinator"]
            let id = try await client.createWorkflow(folder: folder, kind: .agents, roles: roles)
            let workflow = try #require(client.snapshot?.workflows.workflows.first { $0.id == id })
            #expect(workflow.kind == .agents)
            #expect(workflow.agents.map(\.role) == roles)
            #expect(workflow.terminalID == 0)
            #expect(Set(workflow.terminalIDs).count == roles.count)
            #expect(Set(client.snapshot?.terminals.map(\.terminalID) ?? []) == Set(workflow.terminalIDs))

            // Each exit code reaches only its own agent's terminal, so each agent is its own process.
            for (offset, agent) in workflow.agents.enumerated().dropLast() {
                try await client.writeTerminalInput(
                    terminalID: agent.terminalID, bytes: Data("exit \(offset + 3)\n".utf8))
            }
            try await waitForShells {
                workflow.agents.dropLast().enumerated().allSatisfy { offset, agent in
                    client.terminalStatus(for: agent.terminalID)
                        == .exited(BridgeTerminalExit(exitCode: UInt32(offset + 3), signal: nil))
                }
            }
            #expect(client.snapshot?.workflows.workflows.first?.status == .running)
            #expect(client.snapshot?.workflows.workflows.first?.endedAt == nil)
            let last = try #require(workflow.agents.last)
            try await client.writeTerminalInput(terminalID: last.terminalID, bytes: Data("exit 5\n".utf8))
            try await waitForShells { client.snapshot?.workflows.workflows.first?.status == .exited }
            #expect(
                client.terminalStatus(for: last.terminalID) == .exited(BridgeTerminalExit(exitCode: 5, signal: nil)))
            #expect(client.snapshot?.workflows.workflows.first?.endedAt != nil)

            try await client.closeWorkflow(workflowID: id)
            #expect(client.snapshot?.workflows.workflows.isEmpty == true)
            #expect(client.snapshot?.terminals.isEmpty == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func anAgentsWorkflowNeedsRoles() async throws {
        let (client, directory) = try await openFolder()
        let folder = directory.path
        do {
            do {
                _ = try await client.createWorkflow(folder: folder, kind: .agents)
                Issue.record("An agents workflow without roles should be rejected")
            } catch BridgeFailure.commandRejected(let code, _) {
                #expect(code == "invalidAgents")
            }
            #expect(client.snapshot?.workflows.workflows.isEmpty == true)
            #expect(client.snapshot?.terminals.isEmpty == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func agentsRestoreWithTheirRolesAndFreshShellsAfterRelaunch() async throws {
        let (client, directory) = try await openFolder()
        let folder = directory.path
        do {
            let id = try await client.createWorkflow(folder: folder, kind: .agents, roles: ["Implementer", "Reviewer"])
            let original = try #require(client.snapshot?.workflows.workflows.first { $0.id == id })
            await client.stop()
            client.start()
            try await client.waitUntilRunning()
            let restored = try #require(client.snapshot?.workflows.workflows.first { $0.id == id })
            #expect(restored.restored)
            #expect(restored.agents.map(\.id) == original.agents.map(\.id))
            #expect(restored.agents.map(\.role) == ["Implementer", "Reviewer"])
            #expect(restored.terminalIDs.count == 2)
            for terminalID in restored.terminalIDs {
                #expect(client.terminalStatus(for: terminalID) == .running)
            }
            try await client.closeWorkflow(workflowID: id)
            #expect(client.snapshot?.terminals.isEmpty == true)
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    @Test func reopeningAFolderStartsItsRestoredAgentsTerminalsInTheClient() async throws {
        let (client, directory) = try await openFolder()
        let other = TemporaryPath()
        do {
            try FileManager.default.createDirectory(at: other.url, withIntermediateDirectories: true)
            let id = try await client.createWorkflow(
                folder: directory.path, kind: .agents, roles: ["Implementer", "Reviewer"])
            _ = try await client.send(.openFolder(path: other.path))
            try await waitUntil { client.snapshot?.folders.openFolder == other.path }
            #expect(client.snapshot?.terminals.isEmpty == true)
            _ = try await client.send(.openFolder(path: directory.path))
            try await waitUntil { client.snapshot?.workflows.workflows.contains { $0.id == id } == true }
            // The core starts restored shells without terminal events; the workflow state announces them.
            let restored = try #require(client.snapshot?.workflows.workflows.first { $0.id == id })
            #expect(restored.restored)
            #expect(restored.terminalIDs.count == 2)
            for terminalID in restored.terminalIDs {
                #expect(client.terminalStatus(for: terminalID) == .running)
            }
            await client.stop()
        } catch {
            await client.stop()
            throw error
        }
    }

    /// A running client with a fresh folder open. The folder lasts as long as the returned path.
    private func openFolder() async throws -> (BridgeClient, TemporaryPath) {
        let directory = TemporaryPath()
        try FileManager.default.createDirectory(at: directory.url, withIntermediateDirectories: true)
        let client = BridgeClient(transport: BridgeWorker(dataDirectory: directory.url.appending(path: ".twine")))
        client.start()
        do {
            try await client.waitUntilRunning()
            _ = try await client.send(.openFolder(path: directory.path))
            try await waitUntil { client.snapshot?.folders.openFolder == directory.path }
        } catch {
            await client.stop()
            throw error
        }
        return (client, directory)
    }

    /// Agents run the user's login shell, which can take seconds to start on a busy host.
    private func waitForShells(_ condition: () -> Bool) async throws {
        for _ in 0..<1_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(condition())
    }
}
