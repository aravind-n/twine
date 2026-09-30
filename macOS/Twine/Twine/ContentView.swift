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
    @Environment(FileEditorModel.self) private var fileEditor
    @State private var isChoosingFolder = false

    var body: some View {
        content
            .frame(minWidth: 400, minHeight: 250)
            .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url):
                    guard fileEditor.select(nil) else { return }
                    perform(.openFolder(path: url.path(percentEncoded: false)))
                case .failure(let error):
                    folderLogger.error("Folder picker failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            .focusedSceneValue(\.isChoosingFolder, $isChoosingFolder)
            .windowDismissBehavior(fileEditor.isSaving ? .disabled : .automatic)
            .dismissalConfirmationDialog("Discard unsaved changes?", shouldPresent: fileEditor.isDirty) {
                Button("Discard Changes", role: .destructive) { fileEditor.discardAndClose() }
            } message: {
                Text("Cancel to keep editing or save with ⌘S.")
            }
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
            FolderView(path: path)
                .id(path)
        }
    }

    private func perform(_ command: BridgeCommand) {
        Task { await bridgeClient.perform(command) }
    }
}
