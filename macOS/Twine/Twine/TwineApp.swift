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
    @State private var settings = SettingsPopup(dataDirectory: Self.dataDirectory)
    @State private var workflowLayouts = WorkflowLayouts(
        fileURL: Self.dataDirectory.appending(path: "workflow-layouts.json"))

    init() {
        // Each folder has its own window and runtime.
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
            // Configure the core before starting any runtimes. Explicit environment overrides still apply.
            let environment = ProcessInfo.processInfo.environment
            if environment["TWINE_CONFIG_PATH"] == nil && environment["XDG_CONFIG_HOME"] == nil {
                setenv("TWINE_CONFIG_PATH", Self.dataDirectory.appending(path: "config/config.toml").path, 1)
            }
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
                .defaultAppStorage(WorkflowLaunchPreferences.defaultStore())
                .environment(workflowLayouts)
                .environment(harnessModels)
                .environment(\.appZoom, zoom)
                .task {
                    zoom.installKeyboardShortcuts()
                    terminationDelegate.attach(windows: windows, layouts: workflowLayouts, settings: settings)
                }
        }
        .windowToolbarStyle(.unified)
        .defaultWindowPlacement { _, context in
            let available = context.defaultDisplay.visibleRect.size
            let size = CGSize(width: available.width * 0.8, height: available.height * 0.85)
            return WindowPlacement(size: size)
        }
        .restorationBehavior(.disabled)
        .commands {
            SidebarCommands()
            UpdateCommands()
            FolderCommands(windows: windows, settings: settings)
            AppZoomCommands(zoom: zoom)
        }
    }

    private static var dataDirectory: URL { AppPaths.dataDirectory }

}
