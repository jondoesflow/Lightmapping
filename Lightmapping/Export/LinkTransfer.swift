import Foundation
import MultipeerConnectivity
import UIKit

/// Sends finished shows to a nearby device running Receiver mode, which saves and loops
/// them so the sending phone can be put away.
final class LinkService: NSObject, ObservableObject {
    static let serviceType = "lm-link"

    enum Role { case sender, receiver }

    @Published private(set) var peers: [MCPeerID] = []
    @Published private(set) var connected: [MCPeerID] = []
    @Published private(set) var transferProgress: Double?
    @Published private(set) var lastReceived: URL?
    @Published private(set) var status = "Idle"

    let role: Role
    private let me = MCPeerID(displayName: UIDevice.current.name)
    private lazy var session: MCSession = {
        let s = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        s.delegate = self
        return s
    }()
    private var browser: MCNearbyServiceBrowser?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var progressObservation: NSKeyValueObservation?

    init(role: Role) {
        self.role = role
        super.init()
    }

    func start() {
        switch role {
        case .sender:
            let b = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
            b.delegate = self
            b.startBrowsingForPeers()
            browser = b
            status = "Looking for receivers…"
        case .receiver:
            let a = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: ["app": "lightmapping"], serviceType: Self.serviceType)
            a.delegate = self
            a.startAdvertisingPeer()
            advertiser = a
            status = "Waiting for a show…"
        }
    }

    func stop() {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
    }

    func connect(_ peer: MCPeerID) {
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        status = "Connecting to \(peer.displayName)…"
    }

    func send(_ url: URL, to peer: MCPeerID, completion: @escaping (Error?) -> Void) {
        status = "Sending to \(peer.displayName)…"
        let progress = session.sendResource(at: url, withName: url.lastPathComponent, toPeer: peer) { [weak self] error in
            DispatchQueue.main.async {
                self?.transferProgress = nil
                self?.status = error == nil ? "Sent. The receiver is now looping your show." : "Transfer failed"
                completion(error)
            }
        }
        progressObservation = progress?.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.transferProgress = p.fractionCompleted }
        }
    }

    /// Most recent show saved on this receiver.
    static func latestReceivedShow() -> URL? {
        let dir = ProjectStore.shared.receivedDir
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return urls.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }
}

extension LinkService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connected = session.connectedPeers
            switch state {
            case .connected: self.status = "Connected to \(peerID.displayName)"
            case .notConnected: self.status = self.role == .receiver ? "Waiting for a show…" : "Disconnected"
            case .connecting: self.status = "Connecting…"
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        progressObservation = progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async { self?.transferProgress = p.fractionCompleted }
        }
        DispatchQueue.main.async { self.status = "Receiving \(resourceName)…" }
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        guard let localURL, error == nil else {
            DispatchQueue.main.async { self.status = "Receive failed"; self.transferProgress = nil }
            return
        }
        let safeName = (resourceName as NSString).lastPathComponent
        let dest = ProjectStore.shared.receivedDir.appendingPathComponent(safeName)
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.moveItem(at: localURL, to: dest)
        DispatchQueue.main.async {
            self.transferProgress = nil
            self.lastReceived = dest
            self.status = "Playing \(safeName)"
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
}

extension LinkService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { if !self.peers.contains(peerID) { self.peers.append(peerID) } }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.peers.removeAll { $0 == peerID } }
    }
}

extension LinkService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Receiver mode is opt-in on this device, so accept senders on the local network.
        invitationHandler(true, session)
    }
}
