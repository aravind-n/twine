import Foundation
import Observation

@Observable
final class MemoryModel {
    @ObservationIgnored private var catalogRequest = UUID()
    @ObservationIgnored private var readRequest = UUID()
    @ObservationIgnored private let examplesRoot: String
    @ObservationIgnored private let preferences: MemoryPreferences
    private var navigation: MemoryNavigation { didSet { preferences.save(navigation) } }
    var isExpanded: Bool {
        get { navigation.isExpanded }
        set { navigation.isExpanded = newValue }
    }
    var display = MemoryDisplay.rendered
    var navigationURL: URL?
    var linkFailure: String?
    private(set) var catalog: CoreMemoryCatalog?
    private(set) var contents: CoreMemoryRead?
    private(set) var state = MemoryLoadState.idle
    private(set) var readState = MemoryLoadState.idle
    private(set) var generation = UUID()
    var scope: MemoryScope {
        get { navigation.scope }
        set {
            navigation.scope = newValue
            if catalog != nil { reconcileSelection() }
        }
    }
    var selectedID: String? {
        get { navigation[scope].selectedID }
        set { navigation[scope].selectedID = newValue }
    }
    var query: String {
        get { navigation[scope].query }
        set {
            navigation[scope].query = newValue
            reconcileSelection()
        }
    }
    var harness: MemoryHarness? {
        get { navigation[scope].harness }
        set {
            navigation[scope].harness = newValue
            reconcileSelection()
        }
    }
    var kind: MemoryKind? {
        get { navigation[scope].kind }
        set {
            navigation[scope].kind = newValue
            reconcileSelection()
        }
    }
    var group: String? {
        get { navigation[scope].group }
        set {
            navigation[scope].group = newValue
            reconcileSelection()
        }
    }
    var includeExamples = false
    var refreshID = UUID()

    init(folder: String? = nil, defaults: UserDefaults? = nil, examplesRoot: String = MemoryExamples.root) {
        self.examplesRoot = examplesRoot
        preferences = MemoryPreferences(folder: folder, defaults: defaults)
        var saved = preferences.load()
        if MemoryInspection.opensOnLaunch { saved.isExpanded = true }
        if let scope = MemoryInspection.scope { saved.scope = scope }
        if let harness = MemoryInspection.harness { saved[saved.scope].harness = harness }
        if let kind = MemoryInspection.kind { saved[saved.scope].kind = kind }
        navigation = saved
    }

    func scrollID(for scope: MemoryScope) -> String? { navigation[scope].scrollID }
    func rememberScroll(_ id: String?, for scope: MemoryScope) { navigation[scope].scrollID = id }

    var groups: [CoreMemorySource] {
        var seen: Set<String> = []
        return (catalog?.sources ?? []).filter { $0.scope == scope && seen.insert($0.group).inserted }
            .sorted { $0.groupTitle.localizedStandardCompare($1.groupTitle) == .orderedAscending }
    }

    var filteredSources: [CoreMemorySource] {
        (catalog?.sources ?? []).filter { source in
            (harness == nil || source.harness == harness)
                && source.scope == scope
                && (scope != .otherFolder || group == nil || source.group == group)
                && (kind == nil || source.kind == kind)
                && (query.isEmpty
                    || "\(source.title) \(source.location) \(source.kind.title)"
                        .localizedCaseInsensitiveContains(query))
        }
    }

    var selected: CoreMemorySource? { catalog?.sources.first { $0.id == selectedID } }

    var editableFile: FilePreview? {
        guard selected?.isMarkdown == true, selectedID == contents?.source.id,
            let file = contents?.file, file.status == .text, file.version != nil
        else { return nil }
        return file
    }

    func reconcileSelection() {
        defer { revealSelection() }
        guard catalog != nil else { return }
        if let group, !groups.contains(where: { $0.group == group }) { navigation[scope].group = nil }
        guard !filteredSources.contains(where: { $0.id == selectedID }) else { return }
        selectedID = filteredSources.min { selectionRank($0) < selectionRank($1) }?.id
    }

    func refresh() { refreshID = UUID() }

    func request(folder: String?, sourceID: String? = nil) -> CoreMemoryRequest {
        CoreMemoryRequest(folder: folder, sourceID: sourceID, examplesRoot: includeExamples ? examplesRoot : nil)
    }

    func select(_ source: CoreMemorySource) {
        if scope != source.scope { scope = source.scope }
        selectedID = source.id
        navigationURL = nil
    }

    func openLink(_ url: URL) {
        guard
            let source = catalog?.sources.first(where: {
                URL(filePath: $0.location).standardizedFileURL.path == url.standardizedFileURL.path
            })
        else {
            linkFailure = "This link is not a discovered local memory source."
            return
        }
        scope = source.scope
        query = ""
        harness = nil
        group = nil
        kind = nil
        select(source)
        navigationURL = url
        display = .rendered
    }

    private func selectionRank(_ source: CoreMemorySource) -> Int {
        let scopeRank = source.scope == .folder ? 0 : source.scope == .global ? 10 : 20
        let kindRank =
            source.kind == .summary
            ? 0
            : source.kind == .durable
                ? 1
                : source.kind == .instructions ? 2 : source.kind == .configuration ? 8 : 5
        return scopeRank + kindRank
    }

    func revealSelection() {
        if let source = selected {
            if navigationURL?.standardizedFileURL.path != URL(filePath: source.location).standardizedFileURL.path {
                navigationURL = nil
            }
        }
    }

    func load(client: CoreClient, folder: String?) async {
        let token = UUID()
        catalogRequest = token
        state = .loading
        let request = CoreMemoryRequest(folder: folder, examplesRoot: includeExamples ? examplesRoot : nil)
        do {
            let catalog = try await client.memoryCatalog(request)
            try Task.checkCancellation()
            guard catalogRequest == token else { return }
            self.catalog = catalog
            generation = UUID()
            reconcileSelection()
            state = .available
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, catalogRequest == token else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func read(client: CoreClient, folder: String?) async {
        let token = UUID()
        readRequest = token
        guard let sourceID = selectedID else {
            contents = nil
            readState = .idle
            return
        }
        readState = .loading
        contents = nil
        let request = CoreMemoryRequest(
            folder: folder, sourceID: sourceID, examplesRoot: includeExamples ? examplesRoot : nil)
        do {
            let contents = try await client.memoryRead(request)
            try Task.checkCancellation()
            guard selectedID == sourceID, readRequest == token else { return }
            self.contents = contents
            readState = .available
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, selectedID == sourceID, readRequest == token else { return }
            readState = .failed(error.localizedDescription)
        }
    }
}
