import Foundation
import MultipeerConnectivity

/// MultipeerConnectivity-based out-of-band transport for iOS↔iOS UWB
/// peer ranging.
///
/// `PeerOob` advertises and browses for nearby iPhones using a single
/// shared `MCSession` per `start(localName:)` call. Once a peer is
/// invited (or auto-accepts an invitation), discovery tokens are
/// exchanged as a single `Data` payload via `MCSession.send`, and the
/// session is held open for the lifetime of the UWB ranging session.
///
/// Why MultipeerConnectivity instead of BLE GATT?
/// On iOS 17 and later — and notably on iOS 26 — the
/// `NINearbyPeerConfiguration` DISCOVERY → RANGING transition requires
/// an active AWDL/Bonjour sidechannel. With BLE-only OOB the
/// `nearbyd` lifecycle stays in `DISCOVERY active` indefinitely and no
/// samples are produced. Keeping an `MCSession` connected for the
/// duration of ranging satisfies that requirement. See Apple Developer
/// Forums thread 802204.
///
/// The public surface mirrors the peer-mode subset of `BleOob` so
/// `UwbHostApiImpl` can route per-platform with minimal branching:
/// `start(localName:)` / `stop()` / `exchange(...)` / `accept(...)`.
///
/// Foreground only. MultipeerConnectivity does not deliver invitations
/// reliably while the app is backgrounded.
final class PeerOob: NSObject {
  protocol Callback: AnyObject {
    /// - Parameter capability: remote peer's [OobCapability] byte.
    ///   Defaults to `OobCapability.unknownDefault` when the
    ///   advertisement omits the discovery-info entry.
    func onPeerDeviceFound(id: String, name: String, capability: UInt8)
    func onPeerDeviceLost(id: String)
    func onIncomingRequest(id: String, name: String, peerToken: Data)
    func onConnected(id: String, name: String)
    func onDisconnected(id: String, name: String)
    func onError(_ message: String)
  }

  weak var callback: Callback?

  /// MPC service type. Must match `NSBonjourServices` entries
  /// `_flutteruwb-uwb._tcp` / `_flutteruwb-uwb._udp` in the host app's
  /// `Info.plist`. Mismatch causes silent MPC failure.
  ///
  /// Constraints (RFC 6335 / Apple): ≤ 15 chars, lowercase alphanumerics
  /// and hyphens only. `"flutteruwb-uwb"` is 14 chars and complies.
  static let serviceType = "flutteruwb-uwb"

  // MARK: - Internal state

  private var localPeerID: MCPeerID?
  private var session: MCSession?
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?

  /// Discovered peers keyed by `MCPeerID.displayName`.
  private var peers: [String: MCPeerID] = [:]

  private struct PendingExchange {
    let onPeer: (Data) -> Void
    let onErr: (String) -> Void
  }
  private var pendingExchanges: [String: PendingExchange] = [:]

  /// Tokens queued for peers that aren't connected yet. Sent on the next
  /// `.connected` state transition.
  private var queuedSends: [String: Data] = [:]

  // MARK: - Lifecycle

  func start(localName: String) {
    stop()

    let peerID = MCPeerID(displayName: localName)
    let session = MCSession(
      peer: peerID,
      securityIdentity: nil,
      encryptionPreference: .required
    )
    session.delegate = self

    let advertiser = MCNearbyServiceAdvertiser(
      peer: peerID,
      discoveryInfo: OobCapability.discoveryInfo(),
      serviceType: Self.serviceType
    )
    advertiser.delegate = self

    let browser = MCNearbyServiceBrowser(
      peer: peerID,
      serviceType: Self.serviceType
    )
    browser.delegate = self

    self.localPeerID = peerID
    self.session = session
    self.advertiser = advertiser
    self.browser = browser

    advertiser.startAdvertisingPeer()
    browser.startBrowsingForPeers()
  }

  func stop() {
    advertiser?.stopAdvertisingPeer()
    browser?.stopBrowsingForPeers()
    session?.disconnect()

    advertiser = nil
    browser = nil
    session = nil
    localPeerID = nil

    peers.removeAll()
    queuedSends.removeAll()

    for pending in pendingExchanges.values {
      pending.onErr("PeerOob stopped")
    }
    pendingExchanges.removeAll()
  }

  // MARK: - Pairing API

  /// Inviter side. Connect to `deviceId` if needed and send `myToken`.
  /// Completes via `onPeer` when the peer's reply arrives.
  func exchange(
    deviceId: String,
    myToken: Data,
    onPeer: @escaping (Data) -> Void,
    onErr: @escaping (String) -> Void
  ) {
    guard let peerID = peers[deviceId] else {
      onErr("exchange: unknown deviceId \(deviceId)")
      return
    }
    guard let session = session, let browser = browser else {
      onErr("exchange: PeerOob not started")
      return
    }

    pendingExchanges[deviceId] = PendingExchange(onPeer: onPeer, onErr: onErr)

    if session.connectedPeers.contains(peerID) {
      sendNow(myToken, to: peerID, onErr: onErr, deviceId: deviceId)
    } else {
      queuedSends[deviceId] = myToken
      browser.invitePeer(
        peerID,
        to: session,
        withContext: nil,
        timeout: 30
      )
    }
  }

  /// Refuse a previously-received incoming request from `deviceId`.
  ///
  /// `MCSession` doesn't have a first-class "kick this peer" call —
  /// the closest analogue is to drop any pending state and let the
  /// connection idle out. Subsequent traffic from the same peer is
  /// treated as a fresh request.
  func decline(deviceId: String) {
    queuedSends.removeValue(forKey: deviceId)
    if let pending = pendingExchanges.removeValue(forKey: deviceId) {
      pending.onErr("Request declined")
    }
  }

  /// Acceptor side. Send `myToken` as the reply to a previously-received
  /// incoming request.
  func accept(deviceId: String, myToken: Data) {
    guard let peerID = peers[deviceId] else {
      callback?.onError("accept: unknown deviceId \(deviceId)")
      return
    }
    guard let session = session else {
      callback?.onError("accept: PeerOob not started")
      return
    }

    if session.connectedPeers.contains(peerID) {
      sendNow(myToken, to: peerID, onErr: { [weak self] msg in
        self?.callback?.onError(msg)
      }, deviceId: deviceId)
    } else {
      // We received an invitation (auto-accepted) but the connection is
      // still settling. Queue and send on `.connected`.
      queuedSends[deviceId] = myToken
    }
  }

  // MARK: - Helpers

  private func sendNow(
    _ data: Data,
    to peerID: MCPeerID,
    onErr: (String) -> Void,
    deviceId: String
  ) {
    guard let session = session else {
      onErr("send: PeerOob not started")
      return
    }
    do {
      try session.send(data, toPeers: [peerID], with: .reliable)
    } catch {
      pendingExchanges.removeValue(forKey: deviceId)
      onErr("send failed: \(error.localizedDescription)")
    }
  }

  private func failPendingExchange(_ deviceId: String, message: String) {
    if let pending = pendingExchanges.removeValue(forKey: deviceId) {
      pending.onErr(message)
    }
    queuedSends.removeValue(forKey: deviceId)
  }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension PeerOob: MCNearbyServiceBrowserDelegate {
  func browser(
    _ browser: MCNearbyServiceBrowser,
    foundPeer peerID: MCPeerID,
    withDiscoveryInfo info: [String: String]?
  ) {
    let id = peerID.displayName
    // Don't surface ourselves if the OS reflects our own advertisement.
    if id == localPeerID?.displayName { return }
    let isNew = peers[id] == nil
    peers[id] = peerID
    if isNew {
      let capability = OobCapability.parseDiscoveryInfo(info)
      callback?.onPeerDeviceFound(id: id, name: id, capability: capability)
    }
  }

  func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    let id = peerID.displayName
    peers.removeValue(forKey: id)
    callback?.onPeerDeviceLost(id: id)
  }

  func browser(
    _ browser: MCNearbyServiceBrowser,
    didNotStartBrowsingForPeers error: Error
  ) {
    callback?.onError("MPC browser failed: \(error.localizedDescription)")
  }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension PeerOob: MCNearbyServiceAdvertiserDelegate {
  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didReceiveInvitationFromPeer peerID: MCPeerID,
    withContext context: Data?,
    invitationHandler: @escaping (Bool, MCSession?) -> Void
  ) {
    // Auto-accept any invitation. Mirrors the BLE "any peer can write" model.
    let id = peerID.displayName
    if peers[id] == nil {
      peers[id] = peerID
      // We don't get the inviter's discoveryInfo here; assume same-OS
      // peer (the only thing MPC can reach).
      callback?.onPeerDeviceFound(
        id: id,
        name: id,
        capability: OobCapability.iosPeer
      )
    }
    invitationHandler(true, session)
  }

  func advertiser(
    _ advertiser: MCNearbyServiceAdvertiser,
    didNotStartAdvertisingPeer error: Error
  ) {
    callback?.onError("MPC advertiser failed: \(error.localizedDescription)")
  }
}

// MARK: - MCSessionDelegate

extension PeerOob: MCSessionDelegate {
  func session(
    _ session: MCSession,
    peer peerID: MCPeerID,
    didChange state: MCSessionState
  ) {
    let id = peerID.displayName
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch state {
      case .connected:
        if let queued = self.queuedSends.removeValue(forKey: id) {
          self.sendNow(queued, to: peerID, onErr: { [weak self] msg in
            self?.failPendingExchange(id, message: msg)
          }, deviceId: id)
        }
        self.callback?.onConnected(id: id, name: id)
      case .notConnected:
        self.queuedSends.removeValue(forKey: id)
        self.failPendingExchange(id, message: "Peer disconnected")
        self.callback?.onDisconnected(id: id, name: id)
      case .connecting:
        break
      @unknown default:
        break
      }
    }
  }

  func session(
    _ session: MCSession,
    didReceive data: Data,
    fromPeer peerID: MCPeerID
  ) {
    let id = peerID.displayName
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      if self.peers[id] == nil {
        self.peers[id] = peerID
      }
      if let pending = self.pendingExchanges.removeValue(forKey: id) {
        pending.onPeer(data)
      } else {
        self.callback?.onIncomingRequest(id: id, name: id, peerToken: data)
      }
    }
  }

  // Required protocol stubs — we don't use streams/resources.

  func session(
    _ session: MCSession,
    didReceive stream: InputStream,
    withName streamName: String,
    fromPeer peerID: MCPeerID
  ) {}

  func session(
    _ session: MCSession,
    didStartReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID,
    with progress: Progress
  ) {}

  func session(
    _ session: MCSession,
    didFinishReceivingResourceWithName resourceName: String,
    fromPeer peerID: MCPeerID,
    at localURL: URL?,
    withError error: Error?
  ) {}

  func session(
    _ session: MCSession,
    didReceiveCertificate certificate: [Any]?,
    fromPeer peerID: MCPeerID,
    certificateHandler: @escaping (Bool) -> Void
  ) {
    certificateHandler(true)
  }
}
