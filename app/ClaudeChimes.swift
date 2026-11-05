// Claude Chimes: notification sounds for Claude Code, plus a menu bar app.
//
// The same binary runs in two modes:
//   ClaudeChimes --hook <event>   Called by Claude Code hooks (via ~/.claude/chimes/chime-hook).
//                                 Plays the chime and records which sessions are waiting on you.
//   ClaudeChimes                  The menu bar app: volume, mute, waiting sessions, Settings window.
//
// Shared state lives in ~/.claude/chimes:
//   config           sound choices, volume, mute, menu bar options (plain key=value text)
//   sounds/          the chimes (plus any audio files you add)
//   sessions/*.json  one file per Claude session that needs input or has finished a reply

import AppKit
import ServiceManagement
import SwiftUI

let homeDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
let chimesDir = homeDir.appendingPathComponent(".claude/chimes")
let soundsDir = chimesDir.appendingPathComponent("sounds")
let sessionsDir = chimesDir.appendingPathComponent("sessions")
let configURL = chimesDir.appendingPathComponent("config")
let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds")
let audioExts: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]
let repoURL = URL(string: "https://github.com/naumaanh/claude-chimes")!
let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

// MARK: - Config

struct Config: Equatable {
    var input = soundsDir.appendingPathComponent("input-nudge.wav").path
    var done = soundsDir.appendingPathComponent("done-spark.wav").path
    var volume = 0.4
    var muted = false
    var showCount = true      // show the number of sessions needing input next to the icon
    var showFinished = true   // list sessions that finished and are waiting for your reply

    static func load() -> Config {
        var c = Config()
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            let on = (v == "1" || v == "true")
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "input": c.input = (v as NSString).expandingTildeInPath
            case "done": c.done = (v as NSString).expandingTildeInPath
            case "volume": c.volume = min(1, max(0, Double(v) ?? c.volume))
            case "muted": c.muted = on
            case "showCount": c.showCount = on
            case "showFinished": c.showFinished = on
            default: break
            }
        }
        return c
    }

    func save() {
        let text = """
        # Claude Chimes config: written by the menu bar app, read by the chime hook
        input=\(input)
        done=\(done)
        volume=\(String(format: "%.2f", volume))
        muted=\(muted ? 1 : 0)
        showCount=\(showCount ? 1 : 0)
        showFinished=\(showFinished ? 1 : 0)

        """
        try? FileManager.default.createDirectory(at: chimesDir, withIntermediateDirectories: true)
        try? text.write(to: configURL, atomically: true, encoding: .utf8)
    }
}

func soundFiles(in dir: URL) -> [URL] {
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return items.filter { audioExts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func displayName(_ path: String) -> String {
    var name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    for prefix in ["input-", "done-"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
    return name.replacingOccurrences(of: "-", with: " ").capitalized
}

// MARK: - Sessions waiting on you

struct SessionState: Codable, Identifiable {
    enum Status: String, Codable { case needsInput = "needs-input", finished }
    var id: String
    var status: Status
    var title: String
    var cwd: String
    var message: String?
    var appBundleID: String?   // the app the session runs in (Claude desktop, Terminal, iTerm, ...)
    var updatedAt: Date
}

enum Sessions {
    static let maxAge: TimeInterval = 24 * 60 * 60

    static func url(_ id: String) -> URL {
        let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return sessionsDir.appendingPathComponent((safe.isEmpty ? "unknown" : safe) + ".json")
    }

    static func read(_ id: String) -> SessionState? {
        guard let d = try? Data(contentsOf: url(id)) else { return nil }
        return try? decoder.decode(SessionState.self, from: d)
    }

    static func write(_ s: SessionState) {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        if let d = try? encoder.encode(s) { try? d.write(to: url(s.id), options: .atomic) }
    }

    static func remove(_ id: String) { try? FileManager.default.removeItem(at: url(id)) }

    /// All recorded sessions, newest first. Entries older than a day are pruned.
    static func all() -> [SessionState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [SessionState] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let s = try? decoder.decode(SessionState.self, from: d) else { continue }
            if Date().timeIntervalSince(s.updatedAt) > maxAge { try? FileManager.default.removeItem(at: f); continue }
            out.append(s)
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func clearFinished() {
        for s in all() where s.status == .finished { remove(s.id) }
    }

    static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}

/// The session's title as shown in the Claude app: the last "custom-title" entry in its transcript.
func transcriptTitle(_ path: String?) -> String? {
    guard let path, let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) else { return nil }
    var title: String?
    text.enumerateLines { line, _ in
        guard line.contains("\"custom-title\""),
              let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let t = obj["customTitle"] as? String, !t.isEmpty else { return }
        title = t
    }
    return title
}

// MARK: - Hook mode

/// Plays a sound with afplay, detached so the hook returns immediately.
func playDetached(_ path: String, volume: Double) {
    guard volume > 0, FileManager.default.fileExists(atPath: path) else { return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "nohup /usr/bin/afplay -v \"$1\" \"$2\" >/dev/null 2>&1 &", "sh",
                   String(format: "%.2f", volume), path]
    try? p.run()
    p.waitUntilExit()
}

func runHook(_ event: String) -> Never {
    let payload = (try? JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile())) as? [String: Any] ?? [:]
    let env = ProcessInfo.processInfo.environment
    let config = Config.load()
    let id = payload["session_id"] as? String ?? ""
    let cwd = payload["cwd"] as? String ?? ""
    let volume = Double(env["CLAUDE_CHIMES_VOLUME"] ?? "") ?? config.volume

    func record(_ status: SessionState.Status, message: String?) {
        guard !id.isEmpty else { return }
        let previous = Sessions.read(id)
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let title = transcriptTitle(payload["transcript_path"] as? String) ?? previous?.title ?? (folder.isEmpty ? "Claude session" : folder)
        Sessions.write(SessionState(id: id, status: status, title: title, cwd: cwd, message: message,
                                    appBundleID: env["__CFBundleIdentifier"], updatedAt: Date()))
    }

    switch event {
    case "notification":
        // Idle reminders arrive a minute after a reply finished; the Stop chime already covered that.
        let type = payload["notification_type"] as? String ?? ""
        if type == "idle_prompt" || type == "auth_success" { exit(0) }
        record(.needsInput, message: payload["message"] as? String)
        if !config.muted { playDetached(config.input, volume: volume) }
    case "stop":
        record(.finished, message: nil)
        if !config.muted { playDetached(config.done, volume: volume) }
    case "tool":
        // A tool ran, so any permission prompt for this session has been answered.
        if Sessions.read(id)?.status == .needsInput { Sessions.remove(id) }
    case "prompt", "end":
        Sessions.remove(id)
    default:
        break
    }
    exit(0)
}

// MARK: - Shared model

@MainActor
final class AppModel: ObservableObject {
    @Published var config = Config.load() {
        didSet { if config != oldValue { config.save(); onChange?() } }
    }
    @Published var sessions: [SessionState] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    var onChange: (() -> Void)?
    private var player: NSSound?

    var needsInput: [SessionState] { sessions.filter { $0.status == .needsInput } }
    var finished: [SessionState] { sessions.filter { $0.status == .finished } }

    func reloadSessions() {
        sessions = Sessions.all()
        onChange?()
    }

    func reloadConfig() {
        let fresh = Config.load()
        if fresh != config { config = fresh }
    }

    func preview(_ path: String) {
        player?.stop()
        guard let s = NSSound(contentsOfFile: path, byReference: true) else { return }
        s.volume = Float(config.volume)
        player = s
        s.play()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Sound choices for one event: bundled chimes made for it, other chimes and your files, then macOS sounds.
    func soundGroups(for key: String) -> [(String, [URL])] {
        let own = soundFiles(in: soundsDir)
        return [("Chimes", own.filter { $0.lastPathComponent.hasPrefix(key + "-") }),
                ("More", own.filter { !$0.lastPathComponent.hasPrefix(key + "-") }),
                ("macOS", soundFiles(in: systemSoundsDir))].filter { !$0.1.isEmpty }
    }
}

// MARK: - Settings window

struct SoundRow: View {
    let title: String
    let detail: String
    let key: String
    @Binding var path: String
    @ObservedObject var model: AppModel

    var body: some View {
        let groups = model.soundGroups(for: key)
        let known = groups.flatMap { $0.1.map(\.path) }
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker(title, selection: $path) {
                if !known.contains(path) { Text(displayName(path)).tag(path) }
                ForEach(groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1, id: \.path) { Text(displayName($0.path)).tag($0.path) }
                    }
                }
            }
            .labelsHidden()
            .frame(width: 150)
            Button { model.preview(path) } label: { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .help("Play \(displayName(path))")
        }
        .onChange(of: path) { _, new in model.preview(new) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Sounds") {
                SoundRow(title: "Needs input", detail: "Permission prompts and questions",
                         key: "input", path: $model.config.input, model: model)
                SoundRow(title: "Finished", detail: "Claude finished a reply",
                         key: "done", path: $model.config.done, model: model)
            }

            Section("Volume") {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $model.config.volume, in: 0...1) { editing in
                        if !editing { model.preview(model.config.done) }
                    }
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int((model.config.volume * 100).rounded()))%")
                        .monospacedDigit().frame(width: 38, alignment: .trailing)
                }
                Toggle("Mute all chimes", isOn: $model.config.muted)
            }

            Section("Menu Bar") {
                Toggle("Show how many sessions need your input", isOn: $model.config.showCount)
                Toggle("List sessions that finished and are waiting for your reply", isOn: $model.config.showFinished)
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin },
                                                        set: { model.setLaunchAtLogin($0) }))
                LabeledContent("Sounds folder") {
                    Button("Open in Finder") {
                        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(soundsDir)
                    }
                }
                Text("Drop any .wav, .aiff, .mp3, .m4a or .caf file into the sounds folder to add it to the lists.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Claude Chimes \(appVersion)")
                    Spacer()
                    Link("View on GitHub", destination: repoURL)
                }
                Text("Unofficial community project. Not affiliated with Anthropic.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 500, height: 680)
    }
}

// MARK: - Menu bar

enum StatusIcon {
    /// Menu bar icon from the app bundle (Resources/menubar.svg, menubar-muted.svg) as a template image.
    static func image(muted: Bool) -> NSImage? {
        let name = muted ? "menubar-muted" : "menubar"
        let img = Bundle.main.url(forResource: name, withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: muted ? "speaker.slash" : "waveform", accessibilityDescription: nil)
        img?.size = NSSize(width: 18, height: 18)
        img?.isTemplate = true
        img?.accessibilityDescription = "Claude Chimes"
        return img
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    weak var volumeLabel: NSTextField?
    var watcher: DispatchSourceFileSystemObject?
    var refreshTimer: Timer?
    let relative: RelativeDateTimeFormatter = { let f = RelativeDateTimeFormatter(); f.unitsStyle = .short; return f }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu

        if !FileManager.default.fileExists(atPath: configURL.path) { model.config.save() }
        model.onChange = { [weak self] in self?.updateStatusButton() }
        watchSessions()
        model.reloadSessions()
        // Pick up edits made outside the app and age out old sessions.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.reloadConfig()
                self?.model.reloadSessions()
            }
        }
    }

    func watchSessions() {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.model.reloadSessions() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let c = model.config
        button.image = StatusIcon.image(muted: c.muted || c.volume == 0)
        let waiting = model.needsInput.count
        button.title = (c.showCount && waiting > 0) ? "\(waiting)" : ""
        button.toolTip = waiting > 0 ? "Claude Chimes: \(waiting) waiting on you" : "Claude Chimes"
    }

    // Rebuilt each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.reloadConfig()
        model.reloadSessions()
        menu.removeAllItems()

        let needs = model.needsInput
        let finished = model.config.showFinished ? model.finished : []

        menu.addItem(NSMenuItem.sectionHeader(title: "Needs Your Input"))
        if needs.isEmpty {
            let none = NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for s in needs.prefix(10) {
            menu.addItem(sessionItem(s, symbol: "exclamationmark.bubble.fill",
                                     detail: [s.message, ago(s.updatedAt)].compactMap { $0 }.joined(separator: " · ")))
        }

        if !finished.isEmpty {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "Ready for Your Reply"))
            for s in finished.prefix(10) {
                menu.addItem(sessionItem(s, symbol: "checkmark.bubble", detail: "Finished \(ago(s.updatedAt))"))
            }
            menu.addItem(item("Clear Finished", #selector(clearFinished)))
        }

        menu.addItem(.separator())
        menu.addItem(volumeItem())
        let mute = item("Mute", #selector(toggleMute), key: "m")
        mute.state = model.config.muted ? .on : .off
        menu.addItem(mute)

        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Quit Claude Chimes", #selector(quit), key: "q"))
    }

    func ago(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 45 ? "just now" : relative.localizedString(for: date, relativeTo: Date())
    }

    func sessionItem(_ s: SessionState, symbol: String, detail: String) -> NSMenuItem {
        let i = item(s.title, #selector(openSession(_:)))
        i.representedObject = s.appBundleID
        i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        i.toolTip = s.cwd
        if #available(macOS 14.4, *) { i.subtitle = detail } else { i.title = "\(s.title) (\(detail))" }
        return i
    }

    func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    func volumeItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 48))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 27, width: 220, height: 16)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        let slider = NSSlider(value: model.config.volume * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 18, y: 5, width: 224, height: 20)
        slider.isContinuous = true
        view.addSubview(label)
        view.addSubview(slider)
        volumeLabel = label
        refreshVolumeLabel()
        let i = NSMenuItem()
        i.view = view
        return i
    }

    func refreshVolumeLabel() {
        volumeLabel?.stringValue = "Volume  \(Int((model.config.volume * 100).rounded()))%"
    }

    @objc func volumeChanged(_ slider: NSSlider) {
        model.config.volume = slider.doubleValue.rounded() / 100
        refreshVolumeLabel()
        if NSApp.currentEvent?.type == .leftMouseUp { model.preview(model.config.done) }
    }

    @objc func toggleMute() { model.config.muted.toggle() }

    @objc func clearFinished() {
        Sessions.clearFinished()
        model.reloadSessions()
    }

    /// Brings the app the session runs in to the front (Claude desktop, or the terminal for CLI sessions).
    @objc func openSession(_ sender: NSMenuItem) {
        let bundleID = (sender.representedObject as? String) ?? "com.anthropic.claudefordesktop"
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Claude Chimes Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            settingsWindow = w
        }
        model.launchAtLogin = SMAppService.mainApp.status == .enabled
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Entry point

let args = CommandLine.arguments
// Hook mode: run as `chime-hook <event>` (the symlink the installer creates) or `ClaudeChimes --hook <event>`.
// It must never fall through to the menu bar app, or every hook call would launch another copy.
if URL(fileURLWithPath: args[0]).lastPathComponent == "chime-hook" {
    runHook(args.count > 1 ? args[1] : "")
}
if let i = args.firstIndex(of: "--hook") {
    runHook(i + 1 < args.count ? args[i + 1] : "")
}
// Used by uninstall.sh to remove the login item before the app is deleted.
if args.contains("--disable-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// `ClaudeChimes --snapshot-settings out.png` renders the Settings window to a PNG (for docs and checks).
if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SettingsView(model: AppModel()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 680),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
