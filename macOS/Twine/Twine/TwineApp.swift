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
    @State private var coreClient = CoreClient(transport: CoreWorker(dataDirectory: Self.dataDirectory))
    @State private var fileTabs = FileTabsModel()
    @State private var harnessModels = HarnessModelCatalog()
    @State private var workflowLayouts = WorkflowLayouts(
        fileURL: Self.dataDirectory.appending(path: "workflow-layouts.json"))

    init() {
        // The core has one open folder, so a new window tab could only mirror it. SwiftUI has no
        // scene modifier for this.
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
        WindowGroup {
            ContentView()
                .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
                .environment(coreClient)
                .environment(fileTabs)
                .environment(workflowLayouts)
                .environment(harnessModels)
                .task {
                    terminationDelegate.attach(to: coreClient, tabs: fileTabs, layouts: workflowLayouts)
                    // Workflows appear with the core's first snapshot, so their layouts must be ready first.
                    await workflowLayouts.load()
                    coreClient.start()
                }
        }
        .commands {
            FolderCommands(coreClient: coreClient, tabs: fileTabs)
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

    func attach(to coreClient: CoreClient, tabs: FileTabsModel? = nil, layouts: WorkflowLayouts? = nil) {
        self.coreClient = coreClient
        self.tabs = tabs
        self.layouts = layouts
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// The reply closure also lets tests verify that AppKit is released only after shutdown.
    func beginTermination(reply: @escaping @MainActor (Bool) -> Void) -> NSApplication.TerminateReply {
        guard let coreClient else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        guard tabs?.closeAll() != false else { return .terminateCancel }
        isTerminating = true
        Task {
            await coreClient.stopForQuit()
            await layouts?.flush()
            reply(true)
        }
        return .terminateLater
    }
}
