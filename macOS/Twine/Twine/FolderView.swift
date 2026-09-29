import Foundation
import SwiftUI

/// The window content while a folder is open.
struct FolderView: View {
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
