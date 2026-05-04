import XCTest
import CoreBluetooth
@testable import flutter_uwb

/// Smoke-level scaffolding for BleOob unit tests on iOS (accessory side).
/// Real coverage exercises the chunked-write fallback for >185 byte
/// payloads on accessory profiles.
final class BleOobFakeTests: XCTestCase {

    func testCBUUIDFromStringIsStable() {
        let a = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
        let b = CBUUID(string: "0000180A-0000-1000-8000-00805F9B34FB")
        XCTAssertEqual(a, b)
    }
}
