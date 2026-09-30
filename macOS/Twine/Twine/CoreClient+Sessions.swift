import Foundation

extension CoreClient {
    func createSession(folder: String, name: String) async throws -> UInt64 {
        let result = try await sendAndAwaitCompletion(.createSession(folder: folder, name: name))
        guard case .sessionCreated(let sessionID) = result else { throw CoreFailure.unexpectedCommandResult }
        return sessionID
    }

    func renameSession(sessionID: UInt64, name: String) async throws {
        let result = try await sendAndAwaitCompletion(.renameSession(sessionID: sessionID, name: name))
        guard result == .sessionRenamed(sessionID: sessionID) else { throw CoreFailure.unexpectedCommandResult }
    }

    func selectSession(sessionID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.selectSession(sessionID: sessionID))
        guard result == .sessionSelected(sessionID: sessionID) else { throw CoreFailure.unexpectedCommandResult }
    }

    func deleteSession(sessionID: UInt64) async throws {
        let result = try await sendAndAwaitCompletion(.deleteSession(sessionID: sessionID))
        guard result == .sessionDeleted(sessionID: sessionID) else { throw CoreFailure.unexpectedCommandResult }
    }
}
