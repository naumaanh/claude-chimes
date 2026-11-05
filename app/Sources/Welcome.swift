// First-run welcome (shown when the hooks aren't installed yet) and in-app uninstall.

import AppKit
import SwiftUI

/// Holds the welcome window's step. (A class rather than @State: the command-line Swift
/// toolchain used by build.sh doesn't ship SwiftUI's macro plugins.)
final class WelcomeModel: ObservableObject {
    enum Step { case intro, done, failed(String) }
    @Published var step: Step = .intro
}

struct WelcomeView: View {
    @ObservedObject var model = WelcomeModel()
    let onSetUp: () throws -> Void
    let onClose: (_ skipped: Bool) -> Void

    func setUp() {
        do { try onSetUp(); model.step = .done } catch { model.step = .failed(error.localizedDescription) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Chimes").font(.title2.weight(.semibold))
                    Text("Sounds and a waiting list for Claude Code").foregroundStyle(.secondary)
                }
            }

            switch model.step {
            case .intro: intro
            case .done: done
            case .failed(let message): failed(message)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Chimes plays a chime when Claude needs your input or finishes a reply, and lists the sessions waiting on you in the menu bar. It works in the Claude desktop app's Code tab and the claude CLI.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Setting up will:").font(.callout.weight(.medium))
                Label("Add five hooks to ~/.claude/settings.json, after saving a backup. Nothing else in the file changes.", systemImage: "checklist")
                Label("Copy six chimes to ~/.claude/chimes/sounds.", systemImage: "waveform")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            HStack {
                Button("Not Now") { onClose(true) }
                Spacer()
                Button("Set Up") { setUp() }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("You're set up.", systemImage: "checkmark.circle.fill")
                .font(.headline).foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 6) {
                Text("Restart any Claude sessions that are already open so they load the hooks.")
                Text("To avoid hearing two sounds, turn off the Claude app's own notification sound in Claude → Settings → Claude Code → Notification sound.")
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { onClose(false) }.keyboardShortcut(.defaultAction)
            }
        }
    }

    func failed(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Setup didn't finish.", systemImage: "xmark.octagon.fill")
                .font(.headline).foregroundStyle(.red)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Close") { onClose(true) }
                Spacer()
                Button("Try Again") { setUp() }
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

enum Welcome {
    static let skippedKey = "welcomeSkipped"

    /// Show the welcome on launch when the hooks are missing, unless the user chose Not Now before.
    /// (Health and the menu's "Setup needs attention" item still offer Repair after that.)
    static var shouldShow: Bool { !Installer.isSetUp && !UserDefaults.standard.bool(forKey: skippedKey) }
}

@MainActor
enum Uninstall {
    /// Confirms, removes the hooks (and optionally the sounds and config), moves the app to the Trash, and quits.
    static func run() {
        let alert = NSAlert()
        alert.messageText = "Uninstall Claude Chimes?"
        alert.informativeText = "This removes Claude Chimes' hooks from ~/.claude/settings.json (after a backup), turns off Launch at Login, and moves the app to the Trash."
        let keep = NSButton(checkboxWithTitle: "Also delete my sounds and settings", target: nil, action: nil)
        keep.state = .off
        alert.accessoryView = keep
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try Installer.uninstall(deleteData: keep.state == .on)
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't remove the hooks"
            a.informativeText = error.localizedDescription
            a.runModal()
            return
        }
        UserDefaults.standard.removeObject(forKey: Welcome.skippedKey)
        if appBundle.bundleURL.pathExtension == "app" {
            NSWorkspace.shared.recycle([appBundle.bundleURL]) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else {
            NSApp.terminate(nil)
        }
    }
}
