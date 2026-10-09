import SwiftUI

nonisolated struct CoreTraceStorageStatus: Decodable, Sendable {
    let payloadBytes: UInt64
    let payloadFiles: UInt64
    let budgetBytes: UInt64
    let retentionDays: UInt32
    let updatedAt: UInt64
    let pinned: Bool
    let clearGeneration: UInt64
    let completedClearGeneration: UInt64
}

struct TraceStorageControl: View {
    @Environment(CoreClient.self) private var client
    let spanID: UInt64?
    @State private var shown = false
    @State private var status: CoreTraceStorageStatus?
    @State private var failure: String?
    @State private var operation: UInt32 = 0
    @State private var request = 0
    @State private var loading = false

    var body: some View {
        Button("Trace storage", systemImage: "internaldrive") {
            shown = true
            operation = 0
            request += 1
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .accessibilityIdentifier("traceStorage")
        .popover(isPresented: $shown) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trace storage").font(.headline)
                if let status {
                    Text(
                        "\(size(status.payloadBytes)) of \(size(status.budgetBytes)) detail cache"
                            + " · \(status.payloadFiles) files"
                    )
                    .font(.caption).accessibilityIdentifier("traceStorageUsage")
                    Text(
                        status.retentionDays == 0
                            ? "Closed trace history is kept until you delete its session."
                            : "Unpinned, closed trace history expires after \(status.retentionDays) days."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if spanID != nil {
                        Toggle(
                            "Keep full details for this step",
                            isOn: Binding(
                                get: { status.pinned },
                                set: { value in
                                    operation = value ? 1 : 2
                                    request += 1
                                })
                        )
                        .disabled(loading).accessibilityIdentifier("pinTraceDetails")
                    }
                    Button("Clear completed, unpinned details") {
                        operation = 3
                        request += 1
                    }
                    .disabled(loading).accessibilityIdentifier("clearTraceDetails")
                }
                Text(
                    "In-progress and pinned details are protected. Native harness files are kept. "
                        + "Set the budget and retention in [traces] in Settings."
                )
                .font(.caption2).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
                if let failure { Text(failure).font(.caption).foregroundStyle(.secondary) }
            }.padding(16).frame(width: 340)
                .task(id: request) {
                    let currentRequest = request
                    loading = true
                    defer { if request == currentRequest { loading = false } }
                    do {
                        let receipt = try await client.traceStorage(spanID: spanID, operation: operation)
                        try Task.checkCancellation()
                        guard request == currentRequest else { return }
                        status = receipt
                        let until = ContinuousClock.now.advanced(by: .seconds(10))
                        while ContinuousClock.now < until {
                            let pendingClear =
                                operation == 3 && (status?.completedClearGeneration ?? 0) < receipt.clearGeneration
                            let pendingRefresh = operation == 0 && (status?.updatedAt ?? 0) <= receipt.updatedAt
                            guard pendingClear || pendingRefresh else { break }
                            try await Task.sleep(for: .milliseconds(200))
                            let refreshed = try await client.traceStorage(spanID: spanID)
                            try Task.checkCancellation()
                            guard request == currentRequest else { return }
                            status = refreshed
                        }
                        failure =
                            operation == 3 && (status?.completedClearGeneration ?? 0) < receipt.clearGeneration
                            ? "Cleanup is still running. Reopen to check storage usage." : nil
                    } catch is CancellationError { return } catch {
                        guard request == currentRequest else { return }
                        failure = error.localizedDescription
                    }
                }
        }
    }

    private func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .binary)
    }
}
