import Foundation
import Testing

@testable import Twine

@MainActor
struct ReleaseUpdateCheckTests {
    @Test(arguments: [
        ("v0.1.1", "0.1.0", "0.1.1"),
        ("v0.10.0", "0.9.0", "0.10.0"),
        ("v1.0.0", "0.99.99", "1.0.0"),
        ("2.0.0", "1.9.9", "2.0.0"),
    ])
    func newerReleasesOfferTheirVersion(tag: String, current: String, expected: String) throws {
        #expect(try check(tag: tag, current: current) == expected)
    }

    @Test(arguments: [
        ("v0.1.0", "0.1.0"),
        ("v0.9.0", "0.10.0"),
        ("v0.99.99", "1.0.0"),
        ("v1.2.9", "1.3.0"),
    ])
    func equalAndOlderReleasesDoNotOfferAnUpdate(tag: String, current: String) throws {
        #expect(try check(tag: tag, current: current) == nil)
    }

    @Test(arguments: ["nightly-20261006-abcdef", "v1.2.3-beta.1", "v1.2", "v1..3", "v1.2.-3", "v1.2.3extra", ""])
    func invalidReleaseVersionsFail(tag: String) {
        #expect(throws: (any Error).self) { try check(tag: tag, current: "1.2.3") }
    }

    @Test func missingAppVersionFails() {
        #expect(throws: (any Error).self) { try check(tag: "v1.2.3", current: "") }
    }

    @Test(arguments: [403, 404, 429, 500])
    func failedHTTPResponsesAreNotReportedAsUpToDate(status: Int) {
        #expect(throws: (any Error).self) { try check(tag: "v1.2.3", current: "1.2.3", status: status) }
    }

    @Test(arguments: ["{}", "not JSON", "{\"tag_name\":42}"])
    func malformedResponsesFail(json: String) throws {
        let response = try httpResponse(status: 200)
        #expect(throws: (any Error).self) {
            try ReleaseUpdateCheck.availableVersion(in: Data(json.utf8), response: response, currentVersion: "1.2.3")
        }
    }

    private func check(tag: String, current: String, status: Int = 200) throws -> String? {
        let data = try JSONSerialization.data(withJSONObject: ["tag_name": tag])
        return try ReleaseUpdateCheck.availableVersion(
            in: data, response: httpResponse(status: status), currentVersion: current)
    }

    private func httpResponse(status: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://api.github.com/repos/aravind-n/twine/releases/latest"))
        return try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }
}
