// Claude Chimes: a menu bar control for Claude Code notification sounds.
//
// Reads and writes ~/.claude/chimes/config, which ~/.claude/chimes/chime.sh
// (run by Claude Code's Notification and Stop hooks) uses to pick a sound and volume.

import AppKit
import ServiceManagement

let home = FileManager.default.homeDirectoryForCurrentUser
let chimesDir = home.appendingPathComponent(".claude/chimes")
let soundsDir = chimesDir.appendingPathComponent("sounds")
let configURL = chimesDir.appendingPathComponent("config")
let systemSoundsDir = URL(fileURLWithPath: "/System/Library/Sounds")
let audioExts: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "caf"]

// MARK: - Config

struct Config {
    var input: String
    var done: String
    var volume: Double
    var muted: Bool

    static func load() -> Config {
        var c = Config(input: soundsDir.appendingPathComponent("input-nudge.wav").path,
                       done: soundsDir.appendingPathComponent("done-spark.wav").path,
                       volume: 0.4, muted: false)
        guard let text = try? String(contentsOf: configURL, encoding: .utf8) else { return c }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let v = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].trimmingCharacters(in: .whitespaces) {
            case "input": c.input = v
            case "done": c.done = v
            case "volume": c.volume = min(1, max(0, Double(v) ?? c.volume))
            case "muted": c.muted = (v == "1" || v == "true")
            default: break
            }
        }
        return c
    }

    func save() {
        let text = """
        # Claude Chimes config: read by ~/.claude/chimes/chime.sh, written by the menu bar app
        input=\(input)
        done=\(done)
        volume=\(String(format: "%.2f", volume))
        muted=\(muted ? 1 : 0)

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

// MARK: - Menu bar icon

/// Loads the menu bar icon from the app bundle (Resources/menubar.svg and
/// menubar-muted.svg) as a template image, so macOS tints it for light and dark menu bars.
enum StatusIcon {
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

// MARK: - App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var config = Config.load()
    var player: NSSound?
    weak var volumeLabel: NSTextField?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if !FileManager.default.fileExists(atPath: configURL.path) { config.save() }
        updateIcon()
    }

    func updateIcon() {
        statusItem.button?.image = StatusIcon.image(muted: config.muted || config.volume == 0)
        statusItem.button?.toolTip = "Claude Chimes"
    }

    // Rebuilt every time the menu opens, so new files in ~/.claude/chimes/sounds show up.
    func menuNeedsUpdate(_ menu: NSMenu) {
        config = Config.load()
        updateIcon()
        menu.removeAllItems()

        menu.addItem(NSMenuItem.sectionHeader(title: "Claude Chimes"))
        menu.addItem(soundMenuItem(title: "Needs Input", key: "input", symbol: "questionmark.bubble"))
        menu.addItem(soundMenuItem(title: "Finished", key: "done", symbol: "checkmark.bubble"))

        menu.addItem(.separator())
        menu.addItem(volumeItem())
        let mute = item("Mute", #selector(toggleMute), key: "m")
        mute.state = config.muted ? .on : .off
        menu.addItem(mute)

        menu.addItem(.separator())
        menu.addItem(item("Play Needs Input", #selector(playInput), symbol: "play"))
        menu.addItem(item("Play Finished", #selector(playDone), symbol: "play"))

        menu.addItem(.separator())
        menu.addItem(item("Open Sounds Folder", #selector(openFolder), symbol: "folder"))
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit Claude Chimes", #selector(quit), key: "q"))
    }

    func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        return i
    }

    func soundMenuItem(title: String, key: String, symbol: String) -> NSMenuItem {
        let current = key == "input" ? config.input : config.done
        let parent = NSMenuItem(title: "\(title): \(displayName(current))", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let sub = NSMenu()
        sub.autoenablesItems = false

        // Bundled chimes, with the ones made for this event listed first, then macOS sounds.
        let own = soundFiles(in: soundsDir)
        let matching = own.filter { $0.lastPathComponent.hasPrefix(key + "-") }
        let rest = own.filter { !$0.lastPathComponent.hasPrefix(key + "-") }
        addSection(to: sub, title: "Chimes", files: matching, key: key, current: current)
        if !rest.isEmpty { addSection(to: sub, title: "More Chimes", files: rest, key: key, current: current) }
        addSection(to: sub, title: "macOS", files: soundFiles(in: systemSoundsDir), key: key, current: current)

        parent.submenu = sub
        return parent
    }

    func addSection(to menu: NSMenu, title: String, files: [URL], key: String, current: String) {
        guard !files.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem.sectionHeader(title: title))
        for f in files {
            let i = item(displayName(f.path), #selector(chooseSound(_:)))
            i.representedObject = [key, f.path]
            i.state = (f.path == current) ? .on : .off
            menu.addItem(i)
        }
    }

    func volumeItem() -> NSMenuItem {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 48))
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 20, y: 27, width: 210, height: 16)
        label.font = .menuFont(ofSize: 0)
        label.textColor = .secondaryLabelColor
        let slider = NSSlider(value: config.volume * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.frame = NSRect(x: 18, y: 5, width: 214, height: 20)
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
        volumeLabel?.stringValue = "Volume  \(Int((config.volume * 100).rounded()))%"
    }

    @objc func volumeChanged(_ slider: NSSlider) {
        config.volume = slider.doubleValue.rounded() / 100
        refreshVolumeLabel()
        updateIcon()
        config.save()
        if NSApp.currentEvent?.type == .leftMouseUp { preview(config.done) }
    }

    @objc func chooseSound(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else { return }
        if pair[0] == "input" { config.input = pair[1] } else { config.done = pair[1] }
        config.save()
        preview(pair[1])
    }

    @objc func toggleMute() {
        config.muted.toggle()
        config.save()
        updateIcon()
    }

    @objc func playInput() { preview(config.input) }
    @objc func playDone() { preview(config.done) }

    func preview(_ path: String) {
        player?.stop()
        guard let s = NSSound(contentsOfFile: path, byReference: true) else { return }
        s.volume = Float(config.volume)
        player = s
        s.play()
    }

    @objc func openFolder() {
        try? FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(soundsDir)
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            let a = NSAlert()
            a.messageText = "Couldn't change Launch at Login"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc func quit() { NSApp.terminate(nil) }
}

// Used by uninstall.sh to remove the login item before the app is deleted.
if CommandLine.arguments.contains("--disable-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
