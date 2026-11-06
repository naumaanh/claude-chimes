// Hidden self-checks for Other Macs, run from tests/run.sh (selftest) and by hand (loopback).
//   ClaudeChimes --peer-selftest        in memory only: no sockets, no Bonjour, nothing written outside a temp dir
//   ClaudeChimes --peer-loopback-test   two peers in this process pair and sync over 127.0.0.1

import CryptoKit
import Foundation
import Network

enum PeerTests {
    private static var failures = 0

    private static func check(_ name: String, _ ok: @autoclosure () -> Bool) {
        if ok() { print("ok   \(name)") } else { print("FAIL \(name)"); failures += 1 }
    }

    private static func throwsError(_ expected: PeerCrypto.Failure, _ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch { return (error as? PeerCrypto.Failure) == expected }
    }

    private static func sample(_ id: String = "abc123", status: SessionState.Status = .finished) -> SessionState {
        var s = SessionState(id: id, status: status, title: "Sample title", cwd: "/Users/someone/clients/secret-project",
                             message: "Claude needs your permission to use Bash", appBundleID: "com.apple.Terminal",
                             updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        s.turnSeconds = 95
        s.pid = 4242
        s.transcriptPath = "/Users/someone/.claude/projects/x.jsonl"
        s.hostSessionID = "local_123"
        return s
    }

    // MARK: In memory

    static func selftest() -> Bool {
        failures = 0
        let key = SymmetricKey(size: .bits256)
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))   // exact through JSON

        // Framing
        let frame = PeerFrame(t: .hello, id: "A", name: "Mac", commit: "c2Vj")
        let wire = PeerWire.encode(frame)!
        check("frame round-trips", PeerWire.bodyLength(wire.prefix(4)) == wire.count - 4 && PeerWire.decode(wire.dropFirst(4)) == frame)
        check("empty frame length is rejected", PeerWire.bodyLength(Data([0, 0, 0, 0])) == nil)
        check("frame over 64 KB is rejected before reading", PeerWire.bodyLength(Data([0, 1, 0, 1])) == nil)
        check("oversized frame isn't encoded", PeerWire.encode(PeerFrame(t: .sync, id: String(repeating: "x", count: 70_000))) == nil)

        // What leaves the Mac
        let w = WireSession(sample())
        let json = String(decoding: (try? JSONEncoder().encode(w)) ?? Data(), as: UTF8.self)
        check("only the folder name is sent, not the path", w.folder == "secret-project" && !json.contains("/Users/someone"))
        check("process, transcript and desktop IDs aren't sent",
              !json.contains("4242") && !json.contains("jsonl") && !json.contains("local_123") && !json.contains("com.apple"))
        let r = w.session(peerID: "PEER", host: "Mac mini")
        check("remote session is prefixed and labeled",
              r.id == "PEER:abc123" && r.isRemote && r.remoteHost == "Mac mini" && r.desktopLink == nil && r.turnSeconds == 95)

        // Sealing
        let env = PeerEnvelope(kind: .sessions, host: "Mac mini", sentAt: now, sessions: [w])
        let sealed = try! PeerCrypto.seal(env, as: .sync, from: "A", key: key)
        check("sealed frame hides the title", !(sealed.box ?? "").contains("Sample") && String(decoding: try! JSONEncoder().encode(sealed), as: UTF8.self).range(of: "Sample") == nil)
        check("sealed snapshot opens with the pair's key", (try? PeerCrypto.open(sealed, key: key, newerThan: nil, now: now)) == env)
        check("wrong key is rejected", throwsError(.badSeal) { _ = try PeerCrypto.open(sealed, key: SymmetricKey(size: .bits256), newerThan: nil, now: now) })
        var tampered = sealed
        var bytes = Data(base64Encoded: sealed.box!)!
        bytes[bytes.count / 2] ^= 0x01
        tampered.box = bytes.base64EncodedString()
        check("tampered box is rejected", throwsError(.badSeal) { _ = try PeerCrypto.open(tampered, key: key, newerThan: nil, now: now) })
        var relabeled = sealed; relabeled.id = "B"
        check("box relabeled with another sender is rejected", throwsError(.badSeal) { _ = try PeerCrypto.open(relabeled, key: key, newerThan: nil, now: now) })
        var retyped = sealed; retyped.t = .unpair
        check("box replayed as another kind is rejected", throwsError(.badSeal) { _ = try PeerCrypto.open(retyped, key: key, newerThan: nil, now: now) })
        var garbage = sealed; garbage.box = "not base64!"
        check("malformed box is rejected", throwsError(.malformed) { _ = try PeerCrypto.open(garbage, key: key, newerThan: nil, now: now) })
        check("stale message is rejected", throwsError(.stale) { _ = try PeerCrypto.open(sealed, key: key, newerThan: nil, now: now.addingTimeInterval(3600)) })
        check("message from the future is rejected", throwsError(.stale) { _ = try PeerCrypto.open(sealed, key: key, newerThan: nil, now: now.addingTimeInterval(-3600)) })
        check("replayed message is rejected", throwsError(.replay) { _ = try PeerCrypto.open(sealed, key: key, newerThan: now, now: now) })
        check("older message is rejected", throwsError(.replay) { _ = try PeerCrypto.open(sealed, key: key, newerThan: now.addingTimeInterval(5), now: now) })
        let wrongKind = try! PeerCrypto.seal(PeerEnvelope(kind: .unpair, host: "x", sentAt: now), as: .sync, from: "A", key: key)
        check("envelope kind must match the frame", throwsError(.wrongKind) { _ = try PeerCrypto.open(wrongKind, key: key, newerThan: nil, now: now) })

        // Pairing
        let a = Curve25519.KeyAgreement.PrivateKey(), b = Curve25519.KeyAgreement.PrivateKey(), m = Curve25519.KeyAgreement.PrivateKey()
        let ab = try! PeerCrypto.pairing(ours: a, theirs: b.publicKey.rawRepresentation)
        let ba = try! PeerCrypto.pairing(ours: b, theirs: a.publicKey.rawRepresentation)
        check("both Macs derive the same code", ab.code == ba.code)
        check("both Macs derive the same key", ab.key == ba.key)
        check("code is six digits", ab.code.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression) != nil)
        let am = try! PeerCrypto.pairing(ours: a, theirs: m.publicKey.rawRepresentation)
        let mb = try! PeerCrypto.pairing(ours: m, theirs: b.publicKey.rawRepresentation)
        check("a key swapped in the middle changes the code", am.code != ab.code && am.key != mb.key)
        check("an all-zero public key is refused", (try? PeerCrypto.pairing(ours: a, theirs: Data(count: 32))) == nil)
        check("a short public key is refused", (try? PeerCrypto.pairing(ours: a, theirs: Data(count: 5))) == nil)
        check("commitment binds the key", PeerCrypto.commitment(a.publicKey.rawRepresentation) != PeerCrypto.commitment(m.publicKey.rawRepresentation)
              && PeerCrypto.commitment(a.publicKey.rawRepresentation).count == 32)
        let ok = try! PeerCrypto.seal(PeerEnvelope(kind: .pairOK, host: "x", sentAt: now), as: .ok, from: "A", key: ab.key)
        check("pair confirmation opens only with the agreed key",
              (try? PeerCrypto.open(ok, key: ba.key, newerThan: nil, now: now)) != nil
              && (try? PeerCrypto.open(ok, key: am.key, newerThan: nil, now: now)) == nil)

        // Storage
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chimes-peer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("peers.json")
        let keyData = ab.key.withUnsafeBytes { Data($0) }
        PeerStore.save(PeerFile(selfID: "ME", peers: [PairedPeer(id: "B", name: "Mac mini", key: keyData.base64EncodedString(), pairedAt: now)]), to: url)
        let mode = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
        check("peers.json is owner-only (0600)", mode == 0o600)
        let loaded = PeerStore.load(url)
        check("paired Macs load back", loaded.selfID == "ME" && loaded.peers.first?.symmetricKey == ab.key)
        check("a missing file gets a fresh ID", !PeerStore.load(dir.appendingPathComponent("none.json")).selfID.isEmpty)

        // Chimes on the receiving Mac follow its own settings
        var c = Config()
        c.finishedMinSeconds = 30
        var finished = sample(); finished.turnSeconds = 10
        check("short remote turn stays quiet", c.remoteChime(for: finished).note == "skipped-short-turn")
        finished.turnSeconds = 120
        check("long remote turn plays Finished", c.remoteChime(for: finished).path == c.done)
        finished.turnSeconds = 5; finished.failed = true
        check("failed remote turn plays the error sound", c.remoteChime(for: finished).path == c.error)
        check("remote prompt plays Needs input", c.remoteChime(for: sample(status: .needsInput)).path == c.input)
        check("remote working session is silent", c.remoteChime(for: sample(status: .working)).path == nil)
        c.muted = true
        check("muted stays quiet", c.remoteChime(for: sample(status: .needsInput)).note == "muted")
        c.muted = false; c.volume = 0
        check("volume 0 stays quiet", c.remoteChime(for: sample(status: .needsInput)).note == "volume-0")
        c.volume = 0.5; c.quietHours = true; c.quietStart = "00:00"; c.quietEnd = "23:59"
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        check("quiet hours stay quiet", c.remoteChime(for: sample(status: .needsInput), at: noon).note == "quiet-hours")

        print(failures == 0 ? "peer selftest passed" : "peer selftest: \(failures) failed")
        return failures == 0
    }

    // MARK: Over loopback

    @MainActor
    private static func spin(_ timeout: TimeInterval = 5, until done: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        return done()
    }

    @MainActor
    static func loopback() -> Bool {
        failures = 0
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chimes-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var logs: [String] = []
        func node(_ name: String) -> PeerService {
            let p = PeerService(storeURL: dir.appendingPathComponent("\(name).json"), hostName: name, advertise: false)
            p.log = { logs.append("\(name): \($0)") }
            return p
        }
        let a = node("Mac A"), b = node("Mac B")
        // Mac B's app model, wired the way AppDelegate wires it.
        let model = AppModel(peers: b)
        model.persist = false
        var news: [SessionState] = []
        model.onSessionsChanged = { old, new in
            let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
            news += new.filter { s in before[s.id].map { $0.status != s.status || s.updatedAt.timeIntervalSince($0.updatedAt) > 0.5 } ?? true }
        }
        var received: [(String, [SessionState], Bool)] = []
        b.onRemote = { received.append(($0, $1, $2)); model.setRemote($0, $1, baseline: $2) }
        var gone: [String] = []
        b.onRemoteGone = { gone.append($0); model.removeRemote($0) }
        a.start(); b.start()
        check("both listeners start on loopback", spin { a.listenPort != nil && b.listenPort != nil })
        guard let pa = a.listenPort, let pb = b.listenPort else { return false }
        let epA = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: pa)!)
        let epB = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: pb)!)
        a.addNearby(id: b.selfID, name: "Mac B", endpoint: epB)
        b.addNearby(id: a.selfID, name: "Mac A", endpoint: epA)

        // Nothing goes to an unpaired Mac.
        a.localSessionsChanged([sample("before-pairing")])
        _ = spin(0.5) { false }
        check("nothing is sent before pairing", received.isEmpty)

        // Pair: both show the same code; neither commits until both click Pair.
        a.pair(with: a.nearby[0])
        check("both Macs show a code", spin { a.pairing?.code != nil && b.pairing?.code != nil })
        check("the codes match", a.pairing?.code != nil && a.pairing?.code == b.pairing?.code)
        a.confirmPairing()
        _ = spin(0.5) { false }
        check("one side clicking Pair isn't enough", a.paired.isEmpty && b.paired.isEmpty)
        b.confirmPairing()
        check("both Macs are paired", spin { a.pairing?.phase == .done && b.pairing?.phase == .done })
        check("each stores the other", a.paired.first?.id == b.selfID && b.paired.first?.id == a.selfID
              && a.paired.first?.key == b.paired.first?.key && a.paired.first?.name == "Mac B")
        let mode = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("Mac A.json").path))?[.posixPermissions] as? Int
        check("peers file is 0600", mode == 0o600)
        a.cancelPairing(); b.cancelPairing()

        // Sync
        check("pairing sends the current sessions", spin { !received.isEmpty })
        check("first snapshot is the baseline", received.first?.2 == true)
        received = []
        var s = sample("s1", status: .needsInput); s.updatedAt = Date()
        a.localSessionsChanged([s])
        check("a change arrives", spin { received.contains { $0.1.first?.status == .needsInput } })
        let got = received.last?.1.first
        check("arrives labeled with the sending Mac", got?.remoteHost == "Mac A" && got?.id == "\(a.selfID):s1" && got?.cwd == "secret-project")
        check("later snapshots aren't the baseline", received.last?.2 == false)
        let count = received.count
        a.localSessionsChanged([s])
        _ = spin(0.5) { false }
        check("an unchanged list isn't resent", received.count == count)
        a.tick()
        check("the heartbeat resends", spin { received.count > count })

        // What the menu shows on Mac B
        check("the menu lists it under Needs Your Input", model.needsInput.first?.remoteHost == "Mac A")
        check("the baseline wasn't news, the change was", news.count == 1 && news.first?.status == .needsInput)
        if let r = model.needsInput.first { model.hideRemote(r) }
        let n2 = received.count
        a.tick()
        check("a session dismissed here stays hidden through heartbeats", spin { received.count > n2 } && model.needsInput.isEmpty)
        var s2 = s
        s2.status = .finished; s2.turnSeconds = 200; s2.updatedAt = Date().addingTimeInterval(1)
        a.localSessionsChanged([s2])
        check("it comes back when its state changes", spin { model.finished.first?.id == "\(a.selfID):s1" })

        // Forged and unpaired senders
        func raw(_ f: PeerFrame) {
            let params = NWParameters.tcp; params.requiredInterfaceType = .loopback
            let c = FrameConnection(NWConnection(to: epB, using: params))
            c.start(); c.send(f)
        }
        let before = received.count
        let forged = try! PeerCrypto.seal(PeerEnvelope(kind: .sessions, host: "Evil", sentAt: Date(), sessions: [WireSession(sample("evil"))]),
                                          as: .sync, from: a.selfID, key: SymmetricKey(size: .bits256))
        raw(forged)
        check("a forged snapshot is rejected", spin { logs.contains { $0.contains("Mac B: peers reject reason=badSeal") } })
        raw(try! PeerCrypto.seal(PeerEnvelope(kind: .sessions, host: "x", sentAt: Date()), as: .sync, from: "stranger", key: SymmetricKey(size: .bits256)))
        check("an unpaired sender is rejected", spin { logs.contains { $0.contains("reject reason=unpaired from=stranger") } })
        _ = spin(0.3) { false }
        check("rejected messages change nothing", received.count == before)

        // A pairing attempt whose revealed key doesn't match its commitment fails.
        let params = NWParameters.tcp; params.requiredInterfaceType = .loopback
        let evil = FrameConnection(NWConnection(to: epB, using: params), idleTimeout: 5)
        evil.start()
        evil.send(PeerFrame(t: .hello, id: "mallory", name: "Mallory", commit: PeerCrypto.commitment(Data(count: 32)).base64EncodedString()))
        _ = spin(0.5) { b.pairing != nil }
        evil.send(PeerFrame(t: .reveal, id: "mallory", pub: Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation.base64EncodedString()))
        check("a key that breaks its commitment fails pairing", spin {
            if case .failed = b.pairing?.phase { return true } else { return false }
        })
        check("and pairs nothing", b.paired.count == 1)
        b.cancelPairing()
        let busy = FrameConnection(NWConnection(to: epB, using: params), idleTimeout: 5)
        var busyReply: PeerFrame.Kind?
        busy.onFrame = { busyReply = $0.t }
        busy.start()
        busy.send(PeerFrame(t: .hello, id: "mallory", name: "Mallory", commit: PeerCrypto.commitment(Data(count: 32)).base64EncodedString()))
        check("requests right after a failed one are turned away", spin { busyReply == .busy } && b.pairing == nil)

        // Unpair tells the other Mac.
        a.unpair(b.selfID)
        check("unpairing removes it on both Macs", spin { b.paired.isEmpty } && a.paired.isEmpty && gone.contains(a.selfID))
        check("and its sessions leave the menu", model.allSessions.isEmpty)

        a.stop(); b.stop()
        if failures > 0 { logs.forEach { print("  log: \($0)") } }
        print(failures == 0 ? "peer loopback test passed" : "peer loopback test: \(failures) failed")
        return failures == 0
    }
}
