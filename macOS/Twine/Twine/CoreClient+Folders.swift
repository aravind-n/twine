extension CoreClient {
    func refreshGitBranch(folder: String) async throws {
        let receipt = try await send(.refreshGitBranch(folder: folder))
        if let error = receipt.error {
            throw CoreFailure.commandRejected(code: error.code, message: error.message)
        }
    }
}
