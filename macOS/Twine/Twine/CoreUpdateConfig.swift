import Foundation

nonisolated struct CoreUpdateConfig: Decodable, Equatable, Sendable {
    var automaticallyCheck = true
    var automaticallyInstall = false
    var channel = Channel.stable

    enum Channel: String, Decodable, Sendable { case stable, nightly }

    private enum CodingKeys: String, CodingKey {
        case automaticallyCheck = "automatically_check"
        case automaticallyInstall = "automatically_install"
        case channel
    }
}
