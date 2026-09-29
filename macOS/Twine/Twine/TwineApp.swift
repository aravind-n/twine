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
    @State private var bridgeClient = BridgeClient(transport: BridgeWorker(dataDirectory: Self.dataDirectory))

    init() {
        // The core has one open folder, so a new window tab could only mirror it. SwiftUI has no
        // scene modifier for this.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bridgeClient)
                .task {
                    bridgeClient.start()
                }
        }
        .commands {
            FolderCommands(bridgeClient: bridgeClient)
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
