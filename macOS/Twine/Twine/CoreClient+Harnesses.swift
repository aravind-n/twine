import Foundation

extension CoreClient {
    /// Runs the harness's CLI to list its models, which can take a moment.
    func harnessModels(_ harness: CoreHarness) async throws -> CoreHarnessModelsResult {
        guard runState == .running, !isStopping, !isTerminating else { throw CoreFailure.notRunning }
        return try await transport.harnessModels(.init(harness: harness))
    }
}
