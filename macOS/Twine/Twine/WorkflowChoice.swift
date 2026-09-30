import Foundation

enum WorkflowChoice: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case singleAgent = "Single agent"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .singleAgent: "person"
        }
    }

    /// Choices that open a menu instead of acting immediately show a chevron.
    var opensMenu: Bool { self == .singleAgent }

    var detail: String {
        switch self {
        case .terminal: "An interactive shell"
        case .singleAgent: "One agent runs your prompt"
        }
    }
}
