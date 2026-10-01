import Foundation

/// One model a harness offers, as its `--model` flag takes it.
nonisolated struct CoreHarnessModel: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// A heading for long lists, such as pi's provider.
    var group: String?
    /// This model's own effort levels, when they differ by model, as Codex's do.
    var efforts: [String]?
}

/// The models and effort levels a harness offers, read from its own CLI.
nonisolated struct CoreHarnessModels: Decodable, Equatable, Sendable {
    let models: [CoreHarnessModel]
    /// Whether the harness also takes model names it doesn't list, as Claude Code does.
    let allowsCustom: Bool
    /// Every effort level the harness takes, weakest first.
    let efforts: [String]
    /// Whether the harness has a flag that skips its permission prompts. pi has no prompts to skip.
    let supportsYolo: Bool

    /// The levels `model` supports: its own when listed, otherwise the harness's.
    func efforts(for model: String?) -> [String] {
        model.flatMap { id in models.first { $0.id == id }?.efforts } ?? efforts
    }
}

/// A harness's models, or why they couldn't be listed, such as a harness that isn't installed.
nonisolated enum CoreHarnessModelsResult: Decodable, Equatable, Sendable {
    case listed(CoreHarnessModels)
    case failed(String)

    private enum CodingKeys: String, CodingKey { case status, models, message }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .status) {
        case "listed": self = .listed(try container.decode(CoreHarnessModels.self, forKey: .models))
        default: self = .failed(try container.decode(String.self, forKey: .message))
        }
    }
}

nonisolated struct HarnessModelsRequest: Encodable, Sendable {
    let harness: CoreHarness
}

/// A harness with the model and effort level to start it with. `nil` leaves each to the harness's
/// own default. `yolo` skips the harness's permission prompts.
nonisolated struct HarnessChoice: Equatable, Hashable, Sendable {
    var harness: CoreHarness
    var model: String?
    var effort: String?
    var yolo = false

    init(harness: CoreHarness, model: String? = nil, effort: String? = nil, yolo: Bool = false) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.yolo = yolo
    }
}
