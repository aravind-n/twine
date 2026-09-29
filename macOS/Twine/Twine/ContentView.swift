//
//  ContentView.swift
//  Twine
//
//  Created by Aravind Nidadavolu on 9/26/26.
//

import Foundation
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let folderLogger = Logger(subsystem: "com.twineproject.Twine", category: "folders")

/// What the window shows for the bridge's state.
enum WindowContent: Equatable {
    /// Waiting for the core's first snapshot. The window stays empty rather than flash the start page
    /// before the last folder reopens.
    case loading
    case failed(String)
    case startPage(BridgeFolderState)
    case folder(path: String)

    init(connectionState: BridgeConnectionState, snapshot: BridgeSnapshot?) {
        if case .failed(let message) = connectionState {
            self = .failed(message)
        } else if let folders = snapshot?.folders {
            self = if let path = folders.openFolder { .folder(path: path) } else { .startPage(folders) }
        } else {
            self = .loading
        }
    }
}

struct ContentView: View {
    @Environment(BridgeClient.self) private var bridgeClient
    @State private var isChoosingFolder = false

    var body: some View {
        content
            .frame(minWidth: 400, minHeight: 250)
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    perform(.openFolder(path: url.path(percentEncoded: false)))
                case .failure(let error):
                    folderLogger.error("Folder picker failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            .focusedSceneValue(\.isChoosingFolder, $isChoosingFolder)
    }

    @ViewBuilder private var content: some View {
        switch WindowContent(connectionState: bridgeClient.connectionState, snapshot: bridgeClient.snapshot) {
        case .loading:
            Color.clear
        case .failed(let message):
            ContentUnavailableView(
                "Twine Couldn't Start",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .startPage(let folders):
            StartPage(
                folders: folders,
                chooseFolder: { isChoosingFolder = true },
                openFolder: { perform(.openFolder(path: $0)) },
                removeRecentFolder: { perform(.removeRecentFolder(path: $0)) }
            )
        case .folder(let path):
            // A new identity per folder, so the folder's views, such as its terminal, start fresh.
            FolderView(path: path) { perform(.closeFolder) }
                .id(path)
        }
    }

    private func perform(_ command: BridgeCommand) {
        Task { await bridgeClient.perform(command) }
    }
}

/// The window content while a folder is open.
private struct FolderView: View {
    let path: String
    let closeFolder: () -> Void

    var body: some View {
        TerminalSurface(workingDirectory: URL(filePath: path, directoryHint: .isDirectory))
            .padding()
            .navigationTitle(URL(filePath: path).lastPathComponent)
            .navigationSubtitle((path as NSString).abbreviatingWithTildeInPath)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button("Start Page", systemImage: "house", action: closeFolder)
                        .help("Close the folder and return to the start page")
                }
            }
    }
}
