import Foundation
import Observation
import os

private let harnessModelsLogger = Logger(subsystem: "com.twineproject.Twine", category: "harness-models")

/// A harness's models, with their groups worked out once rather than on every menu render.
struct ListedHarnessModels: Equatable {
    struct Group: Equatable, Identifiable {
        let title: String?
        let models: [CoreHarnessModel]
        var id: String { title ?? "" }
    }

    let models: CoreHarnessModels
    /// Models under their headings, in listed order. Ungrouped models come first, as one untitled group.
    let groups: [Group]

    init(_ models: CoreHarnessModels) {
        self.models = models
        var titles: [String?] = []
        var grouped: [String?: [CoreHarnessModel]] = [:]
        for model in models.models {
            if grouped[model.group] == nil { titles.append(model.group) }
            grouped[model.group, default: []].append(model)
        }
        let ordered = titles.filter { $0 == nil } + titles.filter { $0 != nil }
        groups = ordered.map { Group(title: $0, models: grouped[$0] ?? []) }
    }

    /// The levels `model` supports, looked up once per model rather than per menu item.
    func efforts(for model: CoreHarnessModel?) -> [String] {
        model?.efforts ?? models.efforts
    }
}

/// Each harness's models and effort levels, listed once while Twine runs. A harness that couldn't
/// list them is asked again the next time a picker appears.
@Observable
final class HarnessModelCatalog {
    enum Entry: Equatable {
        case loading
        case listed(ListedHarnessModels)
        case failed(String)

        var listed: ListedHarnessModels? {
            if case .listed(let listed) = self { listed } else { nil }
        }

        var models: CoreHarnessModels? { listed?.models }
    }

    private(set) var entries: [CoreHarness: Entry] = [:]
    /// Listings in flight, which only `load` waits on, so they don't need observing.
    @ObservationIgnored private var listings: [CoreHarness: Task<Void, Never>] = [:]

    func entry(for harness: CoreHarness) -> Entry { entries[harness] ?? .loading }

    /// Lists the models of every harness that doesn't have them yet, all at once, and waits for them.
    /// The catalog owns each listing, so a picker that goes away doesn't stop one others wait on.
    func load(using client: CoreClient) async {
        for harness in CoreHarness.allCases {
            switch entries[harness] {
            case nil, .failed:
                entries[harness] = .loading
                listings[harness] = Task { await list(harness, using: client) }
            case .loading, .listed:
                break
            }
        }
        for listing in listings.values { await listing.value }
    }

    private func list(_ harness: CoreHarness, using client: CoreClient) async {
        defer { listings[harness] = nil }
        do {
            switch try await client.harnessModels(harness) {
            case .listed(let models): entries[harness] = .listed(ListedHarnessModels(models))
            case .failed(let message): entries[harness] = .failed(message)
            }
        } catch CoreFailure.notRunning {
            // The core isn't ready yet, so the next picker asks again.
            entries[harness] = nil
        } catch {
            let name = harness.rawValue
            let reason = error.localizedDescription
            harnessModelsLogger.error("Listing \(name, privacy: .public) models failed: \(reason, privacy: .public)")
            entries[harness] = .failed(reason)
        }
    }
}
