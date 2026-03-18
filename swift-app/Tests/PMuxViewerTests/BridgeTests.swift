import XCTest
import CParsecBridge

final class BridgeTests: XCTestCase {
    func testSDKVersion() throws {
        // Just verify the C bridge compiles and the types are accessible
        var status = ParsecClientStatus()
        XCTAssertEqual(MemoryLayout<ParsecClientStatus>.size, MemoryLayout.size(ofValue: status))
        _ = status // suppress warning
    }
}
