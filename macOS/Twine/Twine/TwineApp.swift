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
                .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
                .environment(workflowLayouts)
                .environment(harnessModels)
                .task {
                    terminationDelegate.attach(windows: windows, layouts: workflowLayouts)
                }
        }
        .restorationBehavior(.disabled)
        .commands {
            FolderCommands()
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

    func attach(to coreClient: CoreClient, tabs: FileTabsModel? = nil, layouts: WorkflowLayouts? = nil) {
        self.coreClient = coreClient
        self.tabs = tabs
        self.layouts = layouts
    }

    func attach(windows: FolderWindows, layouts: WorkflowLayouts) {
        self.windows = windows
        self.layouts = layouts
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// The reply closure also lets tests verify that AppKit is released only after shutdown.
    func beginTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        let sessions = Array(windows?.sessions.values ?? [:].values)
        let clients = sessions.map(\.coreClient) + (coreClient.map { [$0] } ?? [])
        let fileTabs = sessions.map(\.tabs) + (tabs.map { [$0] } ?? [])
        guard !clients.isEmpty else { return .terminateNow }
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
