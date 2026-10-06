//
//  TwineApp.swift
//  Twine
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import AppKit
import Foundation
import SwiftUI

@main
struct TwineApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var terminationDelegate
    @State private var initialWindowID = UUID()
    @State private var windows = FolderWindows(dataDirectory: Self.dataDirectory)
    @State private var harnessModels = HarnessModelCatalog()
    @State private var zoom = AppZoom()
    @State private var updater = AppUpdater()
    @State private var settings = SettingsPopup(dataDirectory: Self.dataDirectory)
    @State private var workflowLayouts = WorkflowLayouts(
        fileURL: Self.dataDirectory.appending(path: "workflow-layouts.json"))

    init() {
        // Each folder has its own window and runtime.
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
            // UI tests exercise both appearances without changing the desktop's appearance.
            switch ProcessInfo.processInfo.environment["TWINE_TEST_APPEARANCE"] {
            case "Light":
                NSApplication.shared.appearance = NSAppearance(named: .aqua)
            case "Dark":
                NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
            default:
                break
            }
        #endif
    }

    var body: some Scene {
        WindowGroup(id: "folder", for: UUID.self) { id in
            FolderWindowRoot(id: id.wrappedValue ?? initialWindowID, windows: windows)
                .environment(settings)
                .environment(updater)
                .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
                .environment(workflowLayouts)
                .environment(harnessModels)
                .environment(\.appZoom, zoom)
                .task {
                    zoom.installKeyboardShortcuts()
                    updater.attach(coreClient: settings.coreClient, windows: windows)
                    terminationDelegate.attach(
                        windows: windows, layouts: workflowLayouts, settings: settings, updater: updater)
                }
        }
        .defaultWindowPlacement { _, context in
            let available = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: available.width * 0.8, height: available.height * 0.85)
            return WindowPlacement(size: size)
        }
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
            }
            SidebarCommands()
            FolderCommands(settings: settings)
            AppZoomCommands(zoom: zoom)
        }
    }

    /// Where the core keeps its database: `~/Library/Application Support/Twine`, unless the
    /// `TWINE_DATA_DIRECTORY` environment variable names another directory, as UI tests do to start
    /// from a clean state.
    private static var dataDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["TWINE_DATA_DIRECTORY"] {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return .applicationSupportDirectory.appending(path: "Twine", directoryHint: .isDirectory)
    }
}

@MainActor
final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private var coreClient: CoreClient?
    private var isTerminating = false
    private var tabs: FileTabsModel?
    private var layouts: WorkflowLayouts?
    private var windows: FolderWindows?
    private var settings: SettingsPopup?
    private var updater: AppUpdater?

    func attach(to coreClient: CoreClient, tabs: FileTabsModel? = nil, layouts: WorkflowLayouts? = nil) {
        self.coreClient = coreClient
        self.tabs = tabs
        self.layouts = layouts
    }

    func attach(
        windows: FolderWindows, layouts: WorkflowLayouts, settings: SettingsPopup? = nil, updater: AppUpdater? = nil
    ) {
        self.windows = windows
        self.layouts = layouts
        self.settings = settings
        self.updater = updater
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
            await updater?.finishSavingPreferences()
            await windows?.finishClosingWindows()
            for client in clients { await client.stopForQuit() }
            await layouts?.flush()
            reply(true)
        }
        return .terminateLater
    }
}
