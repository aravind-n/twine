import AppKit

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private var coreClient: CoreClient?
    private var isTerminating = false
    private var tabs: FileTabsModel?
    private var layouts: WorkflowLayouts?
    private var windows: FolderWindows?
    private var settings: SettingsPopup?

    func attach(to coreClient: CoreClient, tabs: FileTabsModel? = nil, layouts: WorkflowLayouts? = nil) {
        self.coreClient = coreClient
        self.tabs = tabs
        self.layouts = layouts
    }

    func attach(windows: FolderWindows, layouts: WorkflowLayouts, settings: SettingsPopup? = nil) {
        self.windows = windows
        self.layouts = layouts
        self.settings = settings
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// The reply closure also lets tests verify that AppKit is released only after shutdown.
    func beginTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard windows != nil || coreClient != nil || settings != nil else { return .terminateNow }
        let sessions = Array(windows?.sessions.values ?? [:].values)
        let clients = sessions.map(\.coreClient) + (coreClient.map { [$0] } ?? [])
        let fileTabs = sessions.map(\.tabs) + (tabs.map { [$0] } ?? [])
        guard settings?.confirmDiscard() != false else { return .terminateCancel }
        guard fileTabs.allSatisfy({ $0.closeAll() }) else { return .terminateCancel }
        isTerminating = true
        windows?.isTerminating = true
        Task {
            await windows?.finishClosingWindows()
            for client in clients { await client.stopForQuit() }
            await layouts?.flush()
            reply(true)
        }
        return .terminateLater
    }
}
