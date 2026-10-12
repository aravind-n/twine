@testable import Twine

extension CoreSnapshot {
    /// A ready snapshot with the default config and no folders or terminals.
    static func testReady(
        sequence: UInt64 = 1, terminal: CoreTerminalConfig = .init(fontFamily: "", fontSize: 13)
    ) -> Self {
        Self(
            sequence: sequence,
            state: CoreApplicationState(status: .ready),
            config: CoreConfig(
                appearance: .init(colorScheme: .system), terminal: terminal),
            folders: CoreFolderState(
                openFolder: nil,
                recentFolders: [],
                unavailableFolder: nil
            )
        )
    }
}
