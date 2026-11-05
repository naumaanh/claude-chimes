// Setup and removal, shared by the first-run welcome, Settings → Health → Repair,
// Settings → Uninstall, install.sh/uninstall.sh, and the --setup/--uninstall flags.
// Edits ~/.claude/settings.json in place: only Claude Chimes' own hooks change, and the
// rest of the file keeps its key order.

import Foundation
import ServiceManagement

enum Installer {
    static let settingsURL = homeDir.appendingPathComponent(".claude/settings.json")
    static let hookLink = chimesDir.appendingPathComponent("chime-hook")
    /// Any hook command containing this belongs to Claude Chimes (covers 1.0's chime.sh too).
    static let ours = "/.claude/chimes/chime"
    /// (hook event, chime-hook argument, runs in the background)
    static let wanted: [(String, String, Bool)] = [
        ("Notification", "notification", false), ("Stop", "stop", false),
        ("UserPromptSubmit", "prompt", true), ("PostToolUse", "tool", true), ("SessionEnd", "end", true),
        ("StopFailure", "failure", false),   // 1.6: a turn ended with an error
        ("PreCompact", "compact", true),     // 1.6: Claude is about to compact the conversation
    ]

    /// Earlier versions installed fewer hooks. If some of ours are present but not all, the user
    /// already chose to set up, so bring their hooks up to date (only ours change).
    static func upgradeIfNeeded() {
        guard case let .success(settings) = readSettings() else { return }
        let ourCommands = wanted.flatMap { ev, _, _ in commands(in: settings, event: ev) }.filter { $0.contains(ours) }
        let legacy = commands(in: settings, event: "Stop").contains { $0.contains(ours) }
        guard (!ourCommands.isEmpty || legacy), !hooksInstalled(settings) else { return }
        if (try? install()) != nil { EventLog.append("upgrade hooks-updated-to=\(wanted.count)") }
    }

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The binary the hook link should point at: this app's own executable.
    static var appBinary: URL? { appBundle.executableURL?.resolvingSymlinksInPath() }
    static var bundledSounds: URL? { appBundle.resourceURL?.appendingPathComponent("sounds") }

    // MARK: settings.json

    /// The parsed settings file. A missing or blank file reads as an empty object.
    static func readSettings() -> Result<JSON, InstallError> {
        guard let data = try? Data(contentsOf: settingsURL) else { return .success(.object([])) }
        if data.allSatisfy({ [0x20, 0x0A, 0x09, 0x0D].contains($0) }) { return .success(.object([])) }
        do {
            let json = try JSON.parse(data)
            guard json.pairs != nil else { return .failure(.init(message: "~/.claude/settings.json isn't a JSON object")) }
            return .success(json)
        } catch {
            return .failure(.init(message: "~/.claude/settings.json isn't valid JSON (\(error.localizedDescription)), so Claude Code may be ignoring it"))
        }
    }

    static func commands(in settings: JSON, event: String) -> [String] {
        (settings["hooks"]?[event]?.array ?? []).flatMap { ($0["hooks"]?.array ?? []).compactMap { $0["command"]?.string } }
    }

    static func hooksInstalled(_ settings: JSON) -> Bool {
        wanted.allSatisfy { ev, arg, _ in commands(in: settings, event: ev).contains { $0.contains("chimes/chime-hook \(arg)") } }
    }

    static var isSetUp: Bool {
        guard case let .success(s) = readSettings() else { return false }
        return hooksInstalled(s) && FileManager.default.isExecutableFile(atPath: hookLink.path)
    }

    /// The settings with every Claude Chimes hook removed and, when `install` is true, the current ones appended.
    /// Events, groups and keys that aren't ours keep their place.
    static func editedHooks(_ settings: JSON, install: Bool) -> JSON {
        var events: [(String, JSON)] = []
        for (event, value) in settings["hooks"]?.pairs ?? [] {
            guard let groups = value.array else { events.append((event, value)); continue }
            let kept: [JSON] = groups.compactMap { group in
                guard let hooks = group["hooks"]?.array else { return group }
                let remaining = hooks.filter { !($0["command"]?.string ?? "").contains(ours) }
                if remaining.isEmpty { return nil }
                return remaining.count == hooks.count ? group : group.setting("hooks", to: .array(remaining))
            }
            if !kept.isEmpty { events.append((event, .array(kept))) }
        }
        if install {
            for (event, arg, background) in wanted {
                var hook: [(String, JSON)] = [("type", .string("command")),
                                              ("command", .string("~/.claude/chimes/chime-hook \(arg)")),
                                              ("timeout", .number("5"))]
                if background { hook.append(("async", .bool(true))) }
                let group = JSON.object([("hooks", .array([.object(hook)]))])
                if let i = events.firstIndex(where: { $0.0 == event }), let groups = events[i].1.array {
                    events[i].1 = .array(groups + [group])
                } else {
                    events.append((event, .array([group])))
                }
            }
        }
        return settings.setting("hooks", to: events.isEmpty ? nil : .object(events))
    }

    /// Writes the settings after a timestamped backup, atomically.
    static func writeSettings(_ settings: JSON) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: settingsURL.path) {
            let stamp = DateFormatter.backupStamp.string(from: Date())
            try? fm.copyItem(at: settingsURL, to: settingsURL.appendingPathExtension("bak-chimes-\(stamp)"))
        }
        try Data((settings.serialized() + "\n").utf8).write(to: settingsURL, options: .atomic)
    }

    // MARK: Files

    /// Copies the bundled chimes into ~/.claude/chimes/sounds, skipping any that are already there.
    @discardableResult
    static func seedSounds() -> Int {
        let fm = FileManager.default
        guard let src = bundledSounds, let files = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return 0 }
        try? fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
        var copied = 0
        for f in files where audioExts.contains(f.pathExtension.lowercased()) {
            let dest = soundsDir.appendingPathComponent(f.lastPathComponent)
            if !fm.fileExists(atPath: dest.path), (try? fm.copyItem(at: f, to: dest)) != nil { copied += 1 }
        }
        return copied
    }

    static func link() throws {
        guard let app = appBinary else { throw InstallError(message: "Can't find this app's executable") }
        let fm = FileManager.default
        try fm.createDirectory(at: chimesDir, withIntermediateDirectories: true)
        try? fm.removeItem(at: hookLink)
        try fm.createSymbolicLink(at: hookLink, withDestinationURL: app)
    }

    // MARK: Setup and removal

    /// Sounds, default config, hook link and hooks. Safe to run again: it replaces only its own hooks.
    static func install() throws {
        let settings: JSON
        switch readSettings() {
        case .success(let s): settings = s
        case .failure(let e): throw InstallError(message: e.message + ". Fix the file by hand, then try again.")
        }
        let copied = seedSounds()
        if !FileManager.default.fileExists(atPath: configURL.path) { Config().save() }
        try link()
        let edited = editedHooks(settings, install: true)
        if edited != settings { try writeSettings(edited) }   // no rewrite (or backup) when already set up
        EventLog.append("setup hooks-written sounds-copied=\(copied) link=\(appBinary?.path ?? "-")")
    }

    /// Removes the hooks, the hook link and session state. With `deleteData`, also the sounds, config and log.
    static func uninstall(deleteData: Bool) throws {
        if case let .success(settings) = readSettings() {
            let edited = editedHooks(settings, install: false)
            if edited != settings { try writeSettings(edited) }
        }
        try? SMAppService.mainApp.unregister()
        let fm = FileManager.default
        try? fm.removeItem(at: hookLink)
        try? fm.removeItem(at: chimesDir.appendingPathComponent("chime.sh"))
        try? fm.removeItem(at: sessionsDir)
        if deleteData { try? fm.removeItem(at: chimesDir) }
    }
}
