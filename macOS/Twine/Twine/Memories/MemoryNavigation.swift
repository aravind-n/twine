import Foundation

/// Only presentation state lives here; source discovery and contents remain owned by the core.
struct MemoryNavigation: Codable {
    var scope = MemoryScope.folder
    var isExpanded = false
    var locations: [MemoryScope: MemoryLocationState] = [:]

    subscript(scope: MemoryScope) -> MemoryLocationState {
        get { locations[scope] ?? MemoryLocationState() }
        set { locations[scope] = newValue }
    }
}

struct MemoryLocationState: Codable {
    var selectedID: String?
    var query = ""
    var harness: MemoryHarness?
    var kind: MemoryKind?
    var group: String?
    var scrollID: String?
}

struct MemoryPreferences {
    private let defaults: UserDefaults
    private let key: String?

    init(folder: String?, defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? WorkflowLaunchPreferences.defaultStore()
        key = folder.map { "memoryNavigation.v1.\($0)" }
    }

    func load() -> MemoryNavigation {
        guard let key, let data = defaults.data(forKey: key),
            let saved = try? JSONDecoder().decode(MemoryNavigation.self, from: data)
        else { return MemoryNavigation() }
        return saved
    }

    func save(_ navigation: MemoryNavigation) {
        guard let key, let data = try? JSONEncoder().encode(navigation) else { return }
        defaults.set(data, forKey: key)
    }
}
