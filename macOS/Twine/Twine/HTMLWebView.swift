import AppKit
import OSLog
import SwiftUI
import WebKit

private let htmlLogger = Logger(subsystem: "com.twineproject.Twine", category: "html-preview")

struct HTMLWebView: NSViewRepresentable {
    let location: HTMLPreviewLocation
    let version: FileVersion?
    let isVisible: Bool
    @Binding var failure: String?
    let openFile: (HTMLPreviewLocation) -> Void

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(location: location, failure: $failure, openFile: openFile)
        coordinator.isVisible = isVisible
        return coordinator
    }

    func makeNSView(context: Context) -> FileContentHost<WKWebView> {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityIdentifier("htmlPreview")
        view.setAccessibilityLabel("HTML preview")
        return FileContentHost(content: view, responder: view)
    }

    func updateNSView(_ host: FileContentHost<WKWebView>, context: Context) {
        let view = host.content
        let coordinator = context.coordinator
        coordinator.failure = $failure
        coordinator.openFile = openFile
        coordinator.isVisible = isVisible
        host.setVisible(isVisible)
        guard !coordinator.hasLoaded || coordinator.version != version || coordinator.location != location else {
            return
        }
        coordinator.hasLoaded = true
        coordinator.version = version
        coordinator.location = location
        coordinator.loadNavigation = view.loadFileURL(location.file, allowingReadAccessTo: location.folder)
    }

    static func dismantleNSView(_ host: FileContentHost<WKWebView>, coordinator: Coordinator) {
        let view = host.content
        coordinator.isActive = false
        view.stopLoading()
        view.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var location: HTMLPreviewLocation
        var version: FileVersion?
        var hasLoaded = false
        var isActive = true
        var isVisible = true
        var failure: Binding<String?>
        var openFile: (HTMLPreviewLocation) -> Void
        var loadNavigation: WKNavigation?
        private let openExternal: (URL) -> Bool

        init(
            location: HTMLPreviewLocation, failure: Binding<String?>,
            openFile: @escaping (HTMLPreviewLocation) -> Void,
            openExternal: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
        ) {
            self.location = location
            self.failure = failure
            self.openFile = openFile
            self.openExternal = openExternal
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard isActive, let url = navigationAction.request.url else { return .cancel }
            if url.scheme == "https" || url.scheme == "http" {
                if isVisible, navigationAction.navigationType == .linkActivated, !openExternal(url) {
                    failure.wrappedValue = "The link couldn't be opened in your browser."
                }
                return .cancel
            }
            let startingLocation = location
            guard let destination = await HTMLPreviewLocation.resolve(file: url, folder: location.folder),
                isActive, location == startingLocation
            else { return .cancel }
            let navigatesMainFrame = navigationAction.targetFrame?.isMainFrame != false
            if navigatesMainFrame && destination.file.path != location.file.path {
                guard isVisible else { return .cancel }
                openFile(destination)
                return .cancel
            }
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            if navigation === loadNavigation { failure.wrappedValue = nil }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error
        ) {
            show(error, for: navigation)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            show(error, for: navigation)
        }

        private func show(_ error: Error, for navigation: WKNavigation?) {
            // Rejected links can also fail in WebKit's sandbox before policy runs. Keep the current page visible.
            guard isActive, let navigation, navigation === loadNavigation,
                (error as NSError).code != NSURLErrorCancelled
            else { return }
            failure.wrappedValue = "The page couldn't be loaded. Switch to Source to inspect the file."
            htmlLogger.error(
                "HTML load failed (\((error as NSError).domain, privacy: .public), code \((error as NSError).code))"
            )
        }
    }
}
