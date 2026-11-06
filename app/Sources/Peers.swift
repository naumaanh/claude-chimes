// Other Macs: your sessions on one Mac also show, chime and pop up banners on your other Macs
// on the same network. Off by default (Settings → Other Macs).
//
// - Discovery: each app advertises `_claudechimes._tcp` over Bonjour, with its random peer ID in
//   the TXT record, and browses for the others.
// - Pairing is required. Nothing is sent to a Mac you haven't paired. Pairing is an X25519 key
//   agreement where the initiator commits to its key first, and both Macs show a 6-digit code
//   derived from the exchange. You check the codes match and click Pair on both. The commitment
//   stops someone in the middle from trying keys until the codes collide.
// - Sync: whenever local sessions change, and every 30 seconds, the app sends each online paired
//   Mac a full snapshot of its sessions, sealed with ChaChaPoly under the pair's key. The receiver
//   replaces what it had for that Mac. A Mac that goes quiet for 100 seconds is dropped.
// - Frames are length-prefixed JSON on TCP, at most 64 KB. A frame from an unpaired sender is
//   dropped before any decryption, and a sealed one must be fresh (within 10 minutes, and newer
//   than the last one accepted from that Mac).
//
// Paired Macs and their keys live in ~/.claude/chimes/peers.json (mode 0600).

import CryptoKit
import Foundation
import Network
import SystemConfiguration

let peersURL = chimesDir.appendingPathComponent("peers.json")
let peerServiceType = "_claudechimes._tcp"

/// This Mac's name as shown in Sharing settings ("Alex's MacBook Pro"). Fast, unlike Host.current().
/// CLAUDE_CHIMES_HOST_NAME overrides it (handy when testing two copies on one Mac).
let localHostName: String = {
    if let n = ProcessInfo.processInfo.environment["CLAUDE_CHIMES_HOST_NAME"], !n.isEmpty { return n }
    return (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
}()

// MARK: - Wire format

/// One session as another Mac sees it: only what the menu and banners need. The folder is just
/// the last path component, never the full path.
struct WireSession: Codable, Equatable {
    var id: String
    var status: SessionState.Status
    var title: String
    var folder: String
    var message: String?
    var failed: Bool?
    var turnSeconds: Double?
    var updatedAt: Date
    var workingSince: Date?

    init(_ s: SessionState) {
        id = String(s.id.prefix(100))
        status = s.status
        title = String(s.title.prefix(200))
        folder = String(URL(fileURLWithPath: s.cwd).lastPathComponent.prefix(100))
        message = s.message.map { String($0.prefix(300)) }
        failed = s.failed
        turnSeconds = s.turnSeconds
        updatedAt = s.updatedAt
        workingSince = s.workingSince
    }

    /// The session as listed on the receiving Mac. Its ID is prefixed with the peer's, so it can't
    /// collide with a local session, and it carries the other Mac's name.
    func session(peerID: String, host: String) -> SessionState {
        var s = SessionState(id: "\(peerID):\(id)", status: status, title: title, cwd: folder, message: message,
                             appBundleID: nil, updatedAt: updatedAt)
        s.failed = failed
        s.turnSeconds = turnSeconds
        s.workingSince = workingSince
        s.remotePeer = peerID
        s.remoteHost = host
        return s
    }
}

/// What a sealed box holds.
struct PeerEnvelope: Codable, Equatable {
    enum Kind: String, Codable { case sessions, unpair, pairOK = "pair-ok" }
    var v = 1
    var kind: Kind
    var host: String
    var sentAt: Date
    var sessions: [WireSession]?
}

/// One frame on the wire.
struct PeerFrame: Codable, Equatable {
    enum Kind: String, Codable {
        case hello = "pair-hello"     // pairing: initiator sends `commit`, responder answers with `pub`
        case reveal = "pair-reveal"   // pairing: initiator reveals the key it committed to
        case ok = "pair-ok"           // pairing: sealed confirmation that you clicked Pair
        case cancel = "pair-cancel"
        case busy = "pair-busy"       // the other Mac isn't taking pairing requests right now
        case sync, unpair             // sealed, between paired Macs
    }
    var t: Kind
    var id: String
    var name: String?
    var pub: String?
    var commit: String?
    var box: String?
}

enum PeerWire {
    static let maxFrame = 64 * 1024

    static func encode(_ f: PeerFrame) -> Data? {
        guard let body = try? JSONEncoder().encode(f), body.count <= maxFrame else { return nil }
        var n = UInt32(body.count).bigEndian
        return Data(bytes: &n, count: 4) + body
    }

    /// The body length from a 4-byte header, or nil if it's empty or over the limit.
    static func bodyLength(_ header: Data) -> Int? {
        guard header.count == 4 else { return nil }
        let n = header.reduce(0) { $0 << 8 | Int($1) }
        return (1...maxFrame).contains(n) ? n : nil
    }

    static func decode(_ body: Data) -> PeerFrame? {
        guard body.count <= maxFrame else { return nil }
        return try? JSONDecoder().decode(PeerFrame.self, from: body)
    }
}

// MARK: - Crypto

enum PeerCrypto {
    enum Failure: Error, Equatable { case malformed, badSeal, wrongKind, stale, replay, weakKey, badCommit }

    static let maxSkew: TimeInterval = 600

    static func aad(_ kind: PeerFrame.Kind, from id: String) -> Data {
        Data("claude-chimes v1 \(kind.rawValue) \(id)".utf8)
    }

    static func seal(_ env: PeerEnvelope, as kind: PeerFrame.Kind, from id: String, key: SymmetricKey) throws -> PeerFrame {
        let plain = try Sessions.encoder.encode(env)
        let box = try ChaChaPoly.seal(plain, using: key, authenticating: aad(kind, from: id))
        return PeerFrame(t: kind, id: id, box: box.combined.base64EncodedString())
    }

    /// Opens a sealed frame and checks it's fresh. `newerThan` is the last sentAt accepted from this sender.
    static func open(_ f: PeerFrame, key: SymmetricKey, newerThan last: Date?, now: Date = Date()) throws -> PeerEnvelope {
        guard let b64 = f.box, let data = Data(base64Encoded: b64),
              let sealed = try? ChaChaPoly.SealedBox(combined: data) else { throw Failure.malformed }
        guard let plain = try? ChaChaPoly.open(sealed, using: key, authenticating: aad(f.t, from: f.id)) else { throw Failure.badSeal }
        guard let env = try? Sessions.decoder.decode(PeerEnvelope.self, from: plain) else { throw Failure.malformed }
        let expected: PeerEnvelope.Kind? = f.t == .sync ? .sessions : f.t == .unpair ? .unpair : f.t == .ok ? .pairOK : nil
        guard env.kind == expected else { throw Failure.wrongKind }
        guard abs(env.sentAt.timeIntervalSince(now)) <= maxSkew else { throw Failure.stale }
        if let last, env.sentAt <= last { throw Failure.replay }
        return env
    }

    static func commitment(_ pub: Data) -> Data { Data(SHA256.hash(data: Data("claude-chimes commit v1".utf8) + pub)) }

    /// The pair's shared key and the 6-digit code both Macs show ("123 456"). Both sides get the same
    /// result from their own private key and the other's public key.
    static func pairing(ours: Curve25519.KeyAgreement.PrivateKey, theirs: Data) throws -> (key: SymmetricKey, code: String) {
        guard let their = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirs) else { throw Failure.malformed }
        let shared = try ours.sharedSecretFromKeyAgreement(with: their)
        // A low-order public key gives an all-zero secret that doesn't depend on our key.
        guard shared.withUnsafeBytes({ $0.contains { $0 != 0 } }) else { throw Failure.weakKey }
        let a = ours.publicKey.rawRepresentation, b = theirs
        let salt = a.lexicographicallyPrecedes(b) ? a + b : b + a
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                 sharedInfo: Data("claude-chimes pair key v1".utf8), outputByteCount: 32)
        let codeBytes = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt,
                                                       sharedInfo: Data("claude-chimes pair code v1".utf8), outputByteCount: 4)
        let n = codeBytes.withUnsafeBytes { $0.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } } % 1_000_000
        let digits = String(format: "%06u", n)
        return (key, "\(digits.prefix(3)) \(digits.suffix(3))")
    }
}

// MARK: - Paired Macs on disk

struct PairedPeer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var key: String          // base64, 32 bytes
    var pairedAt: Date

    var symmetricKey: SymmetricKey? {
        Data(base64Encoded: key).flatMap { $0.count == 32 ? SymmetricKey(data: $0) : nil }
    }
}

struct PeerFile: Codable {
    var selfID: String
    var peers: [PairedPeer]
}

enum PeerStore {
    static func load(_ url: URL = peersURL) -> PeerFile {
        if let d = try? Data(contentsOf: url), let f = try? Sessions.decoder.decode(PeerFile.self, from: d), !f.selfID.isEmpty { return f }
        return PeerFile(selfID: UUID().uuidString, peers: [])
    }

    /// Written owner-only (0600) from the start, then moved into place.
    static func save(_ f: PeerFile, to url: URL = peersURL) {
        guard let d = try? Sessions.encoder.encode(f) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".peers-\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(tmp.path, url.path) != 0 { try? fm.removeItem(at: tmp) }
    }
}

// MARK: - Connections

/// A TCP connection that reads and writes length-prefixed frames, on the main queue.
/// Closes itself after `idleTimeout` seconds without a frame.
@MainActor
final class FrameConnection {
    let conn: NWConnection
    var onFrame: (PeerFrame) -> Void = { _ in }
    var onClose: () -> Void = {}
    var idleTimeout: TimeInterval
    /// CLAUDE_CHIMES_PEER_DEBUG=1 logs every connection state change to events.log.
    static let debug = ProcessInfo.processInfo.environment["CLAUDE_CHIMES_PEER_DEBUG"] == "1"
    private(set) var closed = false
    private var idle: DispatchWorkItem?

    init(_ conn: NWConnection, idleTimeout: TimeInterval = 10) {
        self.conn = conn
        self.idleTimeout = idleTimeout
    }

    func start() {
        conn.stateUpdateHandler = { [weak self, conn] state in
            MainActor.assumeIsolated {
                if Self.debug { EventLog.append("peers debug conn=\(conn.endpoint) state=\(state)") }
                switch state {
                case .failed, .cancelled: self?.finish()
                case .waiting: self?.close()   // refused or unreachable: don't wait around
                default: break
                }
            }
        }
        conn.start(queue: .main)
        touch()
        readHeader()
    }

    func send(_ f: PeerFrame) {
        guard !closed, let d = PeerWire.encode(f) else { return }
        conn.send(content: d, completion: .contentProcessed { _ in })
    }

    func close() {
        guard !closed else { return }
        finish()
        conn.cancel()
    }

    /// Closes after a short delay, so frames just sent get out first.
    func close(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.close() }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        idle?.cancel()
        onClose()
    }

    private func touch() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.close() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: w)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, let n = PeerWire.bodyLength(data) else { self.close(); return }
                self.readBody(n)
            }
        }
    }

    private func readBody(_ n: Int) {
        conn.receive(minimumIncompleteLength: n, maximumLength: n) { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == n, let f = PeerWire.decode(data) else { self.close(); return }
                self.touch()
                self.onFrame(f)
                if !self.closed { self.readHeader() }
            }
        }
    }
}

// MARK: - Pairing

@MainActor
final class PairingSession: ObservableObject, Identifiable {
    enum Role { case initiator, responder }
    enum Phase: Equatable { case connecting, confirm(String), waiting(String), done, failed(String) }

    let id = UUID()
    let role: Role
    let peerID: String
    @Published var peerName: String
    @Published var phase: Phase = .connecting
    let priv = Curve25519.KeyAgreement.PrivateKey()
    var theirCommit: Data?
    var key: SymmetricKey?
    var localOK = false, remoteOK = false
    var conn: FrameConnection?

    init(role: Role, peerID: String, peerName: String) {
        self.role = role
        self.peerID = peerID
        self.peerName = peerName
    }

    var code: String? {
        switch phase {
        case .confirm(let c), .waiting(let c): return c
        default: return nil
        }
    }
    var isFinished: Bool {
        switch phase {
        case .done, .failed: return true
        default: return false
        }
    }
}

// MARK: - Service

@MainActor
final class PeerService: ObservableObject {
    struct Nearby: Identifiable, Equatable {
        let id: String
        var name: String
        var endpoint: NWEndpoint
    }

    @Published private(set) var paired: [PairedPeer]
    @Published private(set) var nearby: [Nearby] = []      // every Mac found, paired or not (never this one)
    @Published private(set) var pairing: PairingSession?
    @Published private(set) var lastSeen: [String: Date] = [:]
    @Published private(set) var running = false

    private(set) var selfID: String
    let hostName: String
    private let storeURL: URL
    private let advertise: Bool
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var connections: [ObjectIdentifier: FrameConnection] = [:]
    private var lastAccepted: [String: Date] = [:]       // newest sentAt per peer (replay protection)
    private var lastSentAt = Date.distantPast
    private var snapshot: [WireSession] = []
    private var lastBroadcast: [WireSession]?
    private var pairingCooldownUntil = Date.distantPast
    private var pairingTimeout: DispatchWorkItem?
    private(set) var listenPort: UInt16?

    static let expireAfter: TimeInterval = 100

    /// A peer's sessions arrived. `baseline` is true for the first snapshot from that Mac (no alerts).
    var onRemote: ((_ peerID: String, _ sessions: [SessionState], _ baseline: Bool) -> Void)?
    /// A peer went quiet, unpaired, or the feature was turned off: drop its sessions.
    var onRemoteGone: ((_ peerID: String) -> Void)?
    /// A pairing started or ended: show or close the pairing window.
    var onPairingChanged: (() -> Void)?
    var log: (String) -> Void = { EventLog.append($0) }

    init(storeURL: URL = peersURL, hostName: String = localHostName, advertise: Bool = true) {
        self.storeURL = storeURL
        self.hostName = hostName
        self.advertise = advertise
        let f = PeerStore.load(storeURL)
        selfID = f.selfID
        paired = f.peers
    }

    func isOnline(_ id: String) -> Bool {
        lastSeen[id].map { Date().timeIntervalSince($0) < Self.expireAfter } ?? false
    }

    // MARK: Start and stop

    func setEnabled(_ on: Bool) {
        if on && !running { start() } else if !on && running { stop() }
    }

    func start() {
        guard !running else { return }
        running = true
        save()   // keeps this Mac's ID stable from now on
        let params = NWParameters.tcp
        if !advertise { params.requiredInterfaceType = .loopback }
        do {
            let l = try NWListener(using: params)
            if advertise {
                l.service = NWListener.Service(name: hostName, type: peerServiceType, domain: nil,
                                               txtRecord: NWTXTRecord(["id": selfID, "v": "1"]).data)
            }
            l.newConnectionHandler = { [weak self] c in
                MainActor.assumeIsolated {
                    if FrameConnection.debug { self?.log("peers debug inbound \(c.endpoint)") }
                    self?.accept(c)
                }
            }
            l.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    if FrameConnection.debug { self?.log("peers debug listener state=\(state)") }
                    switch state {
                    case .ready: self?.listenPort = self?.listener?.port?.rawValue
                    case .failed(let e): self?.log("peers listener-failed \(e)")
                    case .waiting(let e): self?.log("peers listener-waiting \(e)")
                    default: break
                    }
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            log("peers listener-failed \(error)")
        }
        if advertise {
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: peerServiceType, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated { self?.browsed(results) }
            }
            b.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .failed(let e): self?.log("peers browser-failed \(e)")
                    case .waiting(let e): self?.log("peers browser-waiting \(e)")   // e.g. Local Network access denied
                    default: break
                    }
                }
            }
            b.start(queue: .main)
            browser = b
        }
        log("peers on paired=\(paired.count)")
    }

    func stop() {
        guard running else { return }
        running = false
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        listenPort = nil
        if let p = pairing { fail(p, "Other Macs was turned off.") }
        connections.values.forEach { $0.close() }
        connections = [:]
        nearby = []
        for id in lastSeen.keys { onRemoteGone?(id) }
        lastSeen = [:]
        lastBroadcast = nil
        log("peers off")
    }

    private func save() {
        PeerStore.save(PeerFile(selfID: selfID, peers: paired), to: storeURL)
    }

    private func browsed(_ results: Set<NWBrowser.Result>) {
        var found: [String: Nearby] = [:]
        for r in results {
            guard case .bonjour(let txt) = r.metadata, let id = txt["id"], !id.isEmpty, id != selfID,
                  case .service(let name, _, _, _) = r.endpoint, found[id] == nil else { continue }
            found[id] = Nearby(id: id, name: name, endpoint: r.endpoint)
        }
        let before = Set(nearby.map(\.id))
        nearby = found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if Set(found.keys) != before {
            // Counts only: Mac names can be personal and the log ends up in diagnostics.
            log("peers nearby=\(nearby.count) paired-nearby=\(nearby.filter { n in paired.contains { $0.id == n.id } }.count)")
        }
        // A paired Mac just showed up: bring it up to date right away.
        for n in nearby where !before.contains(n.id) && paired.contains(where: { $0.id == n.id }) {
            sendSnapshot(to: n.id)
        }
    }

    /// For tests and the loopback check: a Mac reachable at a fixed address.
    func addNearby(id: String, name: String, endpoint: NWEndpoint) {
        nearby.removeAll { $0.id == id }
        nearby.append(Nearby(id: id, name: name, endpoint: endpoint))
    }

    /// Sample data for --snapshot-settings. Never touches the network or disk.
    func loadDemo() {
        paired = [PairedPeer(id: "demo-1", name: "MacBook Pro", key: "", pairedAt: Date())]
        lastSeen = ["demo-1": Date()]
        nearby = [Nearby(id: "demo-1", name: "MacBook Pro", endpoint: .hostPort(host: "127.0.0.1", port: 1)),
                  Nearby(id: "demo-2", name: "Mac mini", endpoint: .hostPort(host: "127.0.0.1", port: 1))]
    }

    // MARK: Sending

    /// Local sessions changed (or were reloaded). Sends only when something actually changed.
    func localSessionsChanged(_ sessions: [SessionState]) {
        snapshot = sessions.prefix(40).map(WireSession.init)
        guard running, snapshot != lastBroadcast else { return }
        broadcast()
    }

    /// Every 30 seconds: resend to everyone (so they know this Mac is still here), and drop Macs
    /// that have gone quiet.
    func tick() {
        guard running else { return }
        broadcast()
        let now = Date()
        for (id, seen) in lastSeen where now.timeIntervalSince(seen) > Self.expireAfter {
            lastSeen[id] = nil
            onRemoteGone?(id)
            log("peers expired peer=\(id.prefix(8))")
        }
    }

    private func broadcast() {
        lastBroadcast = snapshot
        for p in paired where nearby.contains(where: { $0.id == p.id }) { sendSnapshot(to: p.id) }
    }

    private func nextSentAt() -> Date {
        // Strictly increasing, so the receiver's replay check never drops two sends in the same instant.
        lastSentAt = max(Date(), lastSentAt.addingTimeInterval(0.001))
        return lastSentAt
    }

    private func sendSnapshot(to peerID: String) {
        guard running else { return }
        let env = PeerEnvelope(kind: .sessions, host: hostName, sentAt: nextSentAt(), sessions: snapshot)
        sendSealed(env, as: .sync, to: peerID)
    }

    private func sendSealed(_ env: PeerEnvelope, as kind: PeerFrame.Kind, to peerID: String) {
        guard let peer = paired.first(where: { $0.id == peerID }), let key = peer.symmetricKey,
              let n = nearby.first(where: { $0.id == peerID }),
              let frame = try? PeerCrypto.seal(env, as: kind, from: selfID, key: key) else { return }
        let c = connect(n.endpoint)
        c.send(frame)
        // The receiver closes once it has read the frame; that (or the idle timeout) ends this connection.
    }

    private func connect(_ endpoint: NWEndpoint, idleTimeout: TimeInterval = 10) -> FrameConnection {
        let params = NWParameters.tcp
        if !advertise { params.requiredInterfaceType = .loopback }
        let c = FrameConnection(NWConnection(to: endpoint, using: params), idleTimeout: idleTimeout)
        track(c)
        c.start()
        return c
    }

    private func track(_ c: FrameConnection) {
        let key = ObjectIdentifier(c)
        connections[key] = c
        let previous = c.onClose
        c.onClose = { [weak self] in previous(); self?.connections[key] = nil }
    }

    // MARK: Receiving

    private func accept(_ nw: NWConnection) {
        guard running, connections.count < 32 else { nw.cancel(); return }
        let c = FrameConnection(nw)
        c.onFrame = { [weak self, weak c] f in
            guard let self, let c else { return }
            self.received(f, on: c)
        }
        track(c)
        c.start()
    }

    private func received(_ f: PeerFrame, on c: FrameConnection) {
        switch f.t {
        case .sync, .unpair:
            defer { c.close() }
            // Unpaired senders are dropped before any decryption.
            guard let peer = paired.first(where: { $0.id == f.id }), let key = peer.symmetricKey else {
                log("peers reject reason=unpaired from=\(f.id.prefix(8))")
                return
            }
            let env: PeerEnvelope
            do { env = try PeerCrypto.open(f, key: key, newerThan: lastAccepted[f.id]) } catch {
                log("peers reject reason=\(error) from=\(f.id.prefix(8))")
                return
            }
            lastAccepted[f.id] = env.sentAt
            if f.t == .unpair {
                removePeer(f.id)
                log("peers unpaired-by peer=\(f.id.prefix(8))")
                return
            }
            if env.host != peer.name, !env.host.isEmpty {
                rename(peer.id, to: String(env.host.prefix(100)))
            }
            let baseline = lastSeen[f.id] == nil
            lastSeen[f.id] = Date()
            let list = (env.sessions ?? []).prefix(40).map { $0.session(peerID: f.id, host: env.host) }
            onRemote?(f.id, Array(list), baseline)
        case .hello:
            respondToPairing(f, on: c)
        default:
            c.close()
        }
    }

    private func rename(_ id: String, to name: String) {
        guard let i = paired.firstIndex(where: { $0.id == id }) else { return }
        paired[i].name = name
        save()
    }

    private func removePeer(_ id: String) {
        paired.removeAll { $0.id == id }
        lastAccepted[id] = nil
        lastSeen[id] = nil
        save()
        onRemoteGone?(id)
    }

    // MARK: Pairing

    /// Starts pairing with a Mac found nearby. Both Macs then show the same code.
    func pair(with n: Nearby) {
        guard running, pairing == nil else { return }
        let p = PairingSession(role: .initiator, peerID: n.id, peerName: n.name)
        setPairing(p)
        let c = connect(n.endpoint, idleTimeout: 150)
        p.conn = c
        c.onFrame = { [weak self, weak p] f in
            guard let self, let p else { return }
            self.initiatorReceived(f, p)
        }
        let previous = c.onClose
        c.onClose = { [weak self, weak p] in
            previous()
            guard let self, let p, !p.isFinished else { return }
            self.fail(p, "Lost the connection to \(p.peerName).")
        }
        c.send(PeerFrame(t: .hello, id: selfID, name: hostName,
                         commit: PeerCrypto.commitment(p.priv.publicKey.rawRepresentation).base64EncodedString()))
        log("peers pair-start role=initiator peer=\(n.id.prefix(8))")
    }

    private func initiatorReceived(_ f: PeerFrame, _ p: PairingSession) {
        guard pairing === p, !p.isFinished else { return }
        switch f.t {
        case .hello:
            guard f.id == p.peerID, p.key == nil, let pub = f.pub.flatMap({ Data(base64Encoded: $0) }) else {
                return fail(p, "\(p.peerName) answered unexpectedly.")
            }
            do {
                let (key, code) = try PeerCrypto.pairing(ours: p.priv, theirs: pub)
                p.key = key
                p.conn?.send(PeerFrame(t: .reveal, id: selfID, pub: p.priv.publicKey.rawRepresentation.base64EncodedString()))
                p.phase = .confirm(code)
            } catch {
                fail(p, "\(p.peerName) sent an invalid key.")
            }
        case .ok: remoteConfirmed(f, p)
        case .busy: fail(p, "\(p.peerName) isn't taking pairing requests. Turn on Other Macs there, close any other pairing, and try again.")
        case .cancel: fail(p, "Pairing was canceled on \(p.peerName).")
        default: fail(p, "\(p.peerName) answered unexpectedly.")
        }
    }

    /// An incoming request. Only taken while Other Macs is on, no other pairing is open, and you
    /// haven't just turned one down, so nobody on the network can pile up windows on your screen.
    private func respondToPairing(_ f: PeerFrame, on c: FrameConnection) {
        guard running, pairing == nil, Date() >= pairingCooldownUntil, f.id != selfID, !f.id.isEmpty,
              let commit = f.commit.flatMap({ Data(base64Encoded: $0) }), commit.count == 32 else {
            c.send(PeerFrame(t: .busy, id: selfID))
            c.close(after: 0.5)
            return
        }
        let name = String((f.name ?? "Another Mac").prefix(100))
        let p = PairingSession(role: .responder, peerID: f.id, peerName: name)
        p.theirCommit = commit
        p.conn = c
        c.idleTimeout = 150
        c.onFrame = { [weak self, weak p] f in
            guard let self, let p else { return }
            self.responderReceived(f, p)
        }
        let previous = c.onClose
        c.onClose = { [weak self, weak p] in
            previous()
            guard let self, let p, !p.isFinished else { return }
            self.fail(p, "Lost the connection to \(p.peerName).")
        }
        setPairing(p)
        c.send(PeerFrame(t: .hello, id: selfID, name: hostName, pub: p.priv.publicKey.rawRepresentation.base64EncodedString()))
        log("peers pair-start role=responder peer=\(f.id.prefix(8))")
    }

    private func responderReceived(_ f: PeerFrame, _ p: PairingSession) {
        guard pairing === p, !p.isFinished else { return }
        switch f.t {
        case .reveal:
            guard f.id == p.peerID, p.key == nil, let pub = f.pub.flatMap({ Data(base64Encoded: $0) }),
                  PeerCrypto.commitment(pub) == p.theirCommit else {
                return fail(p, "\(p.peerName) sent a key that doesn't match what it promised. Don't pair.")
            }
            do {
                let (key, code) = try PeerCrypto.pairing(ours: p.priv, theirs: pub)
                p.key = key
                p.phase = .confirm(code)
            } catch {
                fail(p, "\(p.peerName) sent an invalid key.")
            }
        case .ok: remoteConfirmed(f, p)
        case .cancel: fail(p, "Pairing was canceled on \(p.peerName).")
        default: fail(p, "\(p.peerName) answered unexpectedly.")
        }
    }

    private func remoteConfirmed(_ f: PeerFrame, _ p: PairingSession) {
        guard f.id == p.peerID, let key = p.key, (try? PeerCrypto.open(f, key: key, newerThan: nil)) != nil else {
            return fail(p, "\(p.peerName) couldn't prove it has the same code. Don't pair.")
        }
        p.remoteOK = true
        if p.localOK { commit(p) }
    }

    /// You clicked Pair after checking the codes match.
    func confirmPairing() {
        guard let p = pairing, let key = p.key, p.code != nil, !p.localOK else { return }
        p.localOK = true
        if let code = p.code { p.phase = .waiting(code) }
        let env = PeerEnvelope(kind: .pairOK, host: hostName, sentAt: nextSentAt())
        if let frame = try? PeerCrypto.seal(env, as: .ok, from: selfID, key: key) { p.conn?.send(frame) }
        if p.remoteOK { commit(p) }
    }

    func cancelPairing() {
        guard let p = pairing else { return }
        if !p.isFinished {
            p.conn?.send(PeerFrame(t: .cancel, id: selfID))
            p.conn?.close(after: 0.5)
            if p.role == .responder { pairingCooldownUntil = Date().addingTimeInterval(30) }
            log("peers pair-cancel peer=\(p.peerID.prefix(8))")
        }
        setPairing(nil)
    }

    private func commit(_ p: PairingSession) {
        guard let key = p.key else { return }
        let keyData = key.withUnsafeBytes { Data($0) }
        paired.removeAll { $0.id == p.peerID }
        paired.append(PairedPeer(id: p.peerID, name: p.peerName, key: keyData.base64EncodedString(), pairedAt: Date()))
        lastAccepted[p.peerID] = nil
        save()
        p.phase = .done
        pairingTimeout?.cancel()
        p.conn?.close(after: 1)
        log("peers paired peer=\(p.peerID.prefix(8))")
        // Send this Mac's sessions straight away.
        if nearby.contains(where: { $0.id == p.peerID }) { sendSnapshot(to: p.peerID) }
    }

    private func fail(_ p: PairingSession, _ message: String) {
        guard !p.isFinished else { return }
        p.phase = .failed(message)
        pairingTimeout?.cancel()
        p.conn?.close(after: 0.5)
        if p.role == .responder { pairingCooldownUntil = Date().addingTimeInterval(30) }
        log("peers pair-failed peer=\(p.peerID.prefix(8))")
    }

    private func setPairing(_ p: PairingSession?) {
        pairing = p
        pairingTimeout?.cancel()
        if let p {
            let w = DispatchWorkItem { [weak self, weak p] in
                guard let self, let p, !p.isFinished else { return }
                self.fail(p, "Pairing timed out.")
            }
            pairingTimeout = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: w)
        }
        onPairingChanged?()
    }

    // MARK: Unpair

    /// Forgets a paired Mac, and tells it to forget this one if it's reachable.
    func unpair(_ id: String) {
        if running, nearby.contains(where: { $0.id == id }) {
            sendSealed(PeerEnvelope(kind: .unpair, host: hostName, sentAt: nextSentAt()), as: .unpair, to: id)
        }
        removePeer(id)
        log("peers unpair peer=\(id.prefix(8))")
    }
}
