import AppKit
import Foundation
import SwiftUI

struct UpdateCommands: Commands {
    @State private var isChecking = false

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(isChecking ? "Checking for Updates…" : "Check for Updates…") {
                Task { await checkForUpdates() }
            }
            .disabled(isChecking)
        }
    }

    private func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        let alert = NSAlert()
        do {
            let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
            if let latest = try await ReleaseUpdateCheck.availableVersion(currentVersion: current) {
                alert.messageText = "Update Available"
                alert.informativeText = "Twine \(latest) is available. You’re using \(current)."
                alert.addButton(withTitle: "Open Releases Page")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                if let url = URL(string: "https://github.com/aravind-n/twine/releases") {
                    NSWorkspace.shared.open(url)
                }
                return
            }
            alert.messageText = "You’re Up to Date"
            alert.informativeText = "Twine \(current) is up to date."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Could Not Check for Updates"
            alert.informativeText = "Please try again later. \(error.localizedDescription)"
        }
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

enum ReleaseUpdateCheck {
    static func availableVersion(currentVersion: String) async throws -> String? {
        guard let url = URL(string: "https://api.github.com/repos/aravind-n/twine/releases/latest") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Twine", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        return try availableVersion(in: data, response: response, currentVersion: currentVersion)
    }

    static func availableVersion(in data: Data, response: URLResponse, currentVersion: String) throws -> String? {
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let release = try JSONDecoder().decode(LatestRelease.self, from: data)
        let latest = try components(release.tagName)
        let current = try components(currentVersion)
        return current.lexicographicallyPrecedes(latest) ? latest.map(String.init).joined(separator: ".") : nil
    }

    private static func components(_ value: String) throws -> [Int] {
        guard value.wholeMatch(of: /v?[0-9]+\.[0-9]+\.[0-9]+/) != nil else {
            throw URLError(.cannotParseResponse)
        }
        let version = value.hasPrefix("v") ? value.dropFirst() : value[...]
        let numbers = version.split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { throw URLError(.cannotParseResponse) }
        return numbers
    }

}

private struct LatestRelease: Decodable {
    let tagName: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
    }
}
