// Settings → Other Macs, and the pairing window that appears on both Macs while you pair.

import SwiftUI

struct OtherMacsSection: View {
    @ObservedObject var model: AppModel
    @ObservedObject var peers: PeerService

    var body: some View {
        Section("Other Macs") {
            Toggle("Share sessions with my other Macs", isOn: $model.config.otherMacs)
            Text("Sessions here show, chime and pop up banners on your paired Macs on the same network, and theirs show here. Only Macs you pair get anything, and it's encrypted.")
                .font(.caption).foregroundStyle(.secondary)

            ForEach(peers.paired) { p in
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name)
                        Text(status(of: p)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Unpair") { peers.unpair(p.id) }
                }
            }

            if model.config.otherMacs {
                let unpaired = peers.nearby.filter { n in !peers.paired.contains { $0.id == n.id } }
                ForEach(unpaired) { n in
                    HStack(spacing: 10) {
                        Image(systemName: "laptopcomputer").foregroundStyle(.tertiary).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(n.name)
                            Text("Nearby, not paired").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pair…") { peers.pair(with: n) }
                            .disabled(peers.pairing != nil)
                    }
                }
                if unpaired.isEmpty {
                    Text(peers.paired.isEmpty
                         ? "Looking for Macs nearby. Turn on Other Macs in Claude Chimes on your other Mac too."
                         : "No other Macs nearby to pair.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !peers.paired.isEmpty {
                Text("Turned off, so nothing is shared. Your paired Macs are kept.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    func status(of p: PairedPeer) -> String {
        guard model.config.otherMacs else { return "Paired" }
        if peers.isOnline(p.id) {
            let n = model.remote[p.id]?.count ?? 0
            return n == 0 ? "Connected" : "Connected · \(n) session\(n == 1 ? "" : "s")"
        }
        return peers.nearby.contains { $0.id == p.id } ? "Nearby, connecting" : "Not on this network"
    }
}

struct PairingView: View {
    @ObservedObject var session: PairingSession
    let onPair: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "laptopcomputer").font(.system(size: 30)).foregroundStyle(.secondary)
            Text("Pair with \(session.peerName)").font(.headline)
            switch session.phase {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting…").foregroundStyle(.secondary)
                buttons(pair: false)
            case .confirm(let code), .waiting(let code):
                Text(code)
                    .font(.system(size: 34, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code)")
                if case .waiting = session.phase {
                    Text("Waiting for you to click Pair on \(session.peerName)…")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    buttons(pair: false)
                } else {
                    Text("Check that \(session.peerName) shows the same code, then click Pair on both Macs. If the codes differ, cancel.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    buttons(pair: true)
                }
            case .done:
                Text("Paired. Sessions from \(session.peerName) now show in the menu, and yours show there.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.defaultAction) }
            case .failed(let message):
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction) }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    @ViewBuilder func buttons(pair: Bool) -> some View {
        HStack {
            Spacer()
            Button("Cancel", action: onClose).keyboardShortcut(.cancelAction)
            Button("Pair", action: onPair).keyboardShortcut(.defaultAction).disabled(!pair)
        }
    }
}
