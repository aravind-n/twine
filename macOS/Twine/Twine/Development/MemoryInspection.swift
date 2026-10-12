import Foundation

nonisolated enum MemoryInspection {
    static var opensOnLaunch: Bool {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_PROTOTYPE_LAYOUT"] != nil
                || ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION"] == "1"
        #else
            false
        #endif
    }
    static var harness: MemoryHarness? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_HARNESS"].flatMap(
                MemoryHarness.init(rawValue:))
        #else
            nil
        #endif
    }
    static var scope: MemoryScope? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_SCOPE"].flatMap(MemoryScope.init(rawValue:))
        #else
            nil
        #endif
    }
    static var kind: MemoryKind? {
        #if DEBUG
            ProcessInfo.processInfo.environment["TWINE_MEMORY_INSPECTION_KIND"].flatMap(MemoryKind.init(rawValue:))
        #else
            nil
        #endif
    }
}
