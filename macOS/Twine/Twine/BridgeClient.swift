import TwineBridge

struct BridgeClient {
    func add(_ left: UInt64, _ right: UInt64) -> UInt64 {
        twine_bridge_add(left, right)
    }
}
