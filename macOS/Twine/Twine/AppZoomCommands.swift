import SwiftUI

struct AppZoomCommands: Commands {
    let zoom: AppZoom

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Zoom In", action: zoom.zoomIn)
                .keyboardShortcut("+")
                .disabled(!zoom.canZoomIn)
            Button("Zoom Out", action: zoom.zoomOut)
                .keyboardShortcut("-")
                .disabled(!zoom.canZoomOut)
            Button("Actual Size", action: zoom.reset)
                .keyboardShortcut("0")
        }
    }
}
