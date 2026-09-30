import Foundation
import OSLog
import Observation

nonisolated private let layoutLogger = Logger(subsystem: "com.twineproject.Twine", category: "layouts")

/// Each agents workflow's layout, saved as JSON beside the core's database because it refers to the
/// database's workflow and agent IDs. Layouts are grouped by folder, so each folder's workflow list
/// can prune the layouts of workflows that closed. The core never reads this file.
@MainActor
@Observable
final class WorkflowLayouts {
    private var layouts: [String: [String: WorkflowLayout]] = [:]
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var pendingSave: Data?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func layout(for workflowID: UInt64, in folder: String) -> WorkflowLayout {
        layouts[folder]?[String(workflowID)] ?? WorkflowLayout()
    }

    func setLayout(_ layout: WorkflowLayout, for workflowID: UInt64, in folder: String) {
        guard layout != self.layout(for: workflowID, in: folder) else { return }
        layouts[folder, default: [:]][String(workflowID)] = layout
        save()
    }

    /// Forgets the layouts of a folder's workflows that closed. Only the folder's loaded workflow state
    /// lists all of its workflows, which the core gives for every session.
    func removeClosedWorkflows(in folder: String, state: CoreWorkflowState?) {
        guard let state, state.sessionsInitialized, state.session?.folder == folder, let saved = layouts[folder]
        else { return }
        let kept = Set(state.workflows.map { String($0.id) })
        let remaining = saved.filter { kept.contains($0.key) }
        guard remaining.count != saved.count else { return }
        layouts[folder] = remaining.isEmpty ? nil : remaining
        save()
    }

    /// Reads the saved layouts, once. A missing or unreadable file leaves every workflow in tab mode.
    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let saved = await Self.read(fileURL) else { return }
        // A layout set while the file was read is newer than the file's.
        layouts.merge(saved) { current, saved in current.merging(saved) { current, _ in current } }
    }

    /// Waits until the file holds every change so far, such as before the app quits.
    func flush() async {
        await saveTask?.value
    }

    /// Writes off the main actor, one write at a time. Changes made during a write are coalesced into
    /// the next one, so dragging a divider doesn't queue a write per step.
    private func save() {
        do {
            pendingSave = try JSONEncoder().encode(layouts)
        } catch {
            layoutLogger.error("Could not encode workflow layouts: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard saveTask == nil else { return }
        saveTask = Task { [fileURL] in
            while let data = pendingSave {
                pendingSave = nil
                await Self.write(data, to: fileURL)
            }
            saveTask = nil
        }
    }

    @concurrent
    private static func read(_ url: URL) async -> [String: [String: WorkflowLayout]]? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            layoutLogger.error("Could not read workflow layouts: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        do {
            return try JSONDecoder().decode([String: [String: WorkflowLayout]].self, from: data)
        } catch {
            layoutLogger.error("Could not decode workflow layouts: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    @concurrent
    private static func write(_ data: Data, to url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            layoutLogger.error("Could not save workflow layouts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
