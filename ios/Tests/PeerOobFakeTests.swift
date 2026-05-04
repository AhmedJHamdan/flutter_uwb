import XCTest
import MultipeerConnectivity
@testable import flutter_uwb

/// Smoke-level scaffolding for PeerOob unit tests.
///
/// `PeerOob` wraps `MCNearbyServiceAdvertiser` / `MCNearbyServiceBrowser`
/// and an `MCSession`. A fuller harness would fake those Apple types
/// behind a thin protocol.
final class PeerOobFakeTests: XCTestCase {

    func testMCPeerIDDisplayNameRoundTrips() {
        let peer = MCPeerID(displayName: "test-peer")
        XCTAssertEqual(peer.displayName, "test-peer")
    }
}
