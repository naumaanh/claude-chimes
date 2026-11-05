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
/// The real app bundle, even when this binary runs through the ~/.claude/chimes/chime-hook symlink
/// (Bundle.main would then be ~/.claude/chimes).
let appBundle: Bundle = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let contents = exe.deletingLastPathComponent().deletingLastPathComponent()
    if contents.lastPathComponent == "Contents", let b = Bundle(url: contents.deletingLastPathComponent()) { return b }
    return Bundle.main
}()
let appVersion = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

// MARK: - Config

struct Config: Equatable {
    var input = soundsDir.appendingPathComponent("input-nudge.wav").path
    var done = soundsDir.appendingPathComponent("done-spark.wav").path
    var error = soundsDir.appendingPathComponent("error-dip.wav").path
    var volume = 0.4
    var muted = false
    var badge = Badge.all     // what the number badge on the menu bar icon counts
    var showFinished = true   // list sessions that finished and are waiting for your reply
    var showWorking = true    // list sessions Claude is working on right now
    var banner = Badge.all    // which sessions pop up an on-screen banner (same three choices as the badge)
    var bannerPosition = BannerPosition.topRight
    var bannerSeconds = 8     // 0 keeps a banner until you dismiss it
    var finishedMinSeconds = 30   // only chime/banner Finished for turns at least this long (0 = always)
    var reminderMinutes = 5       // remind once about a prompt left unanswered this long (0 = off)
    var compactChime = false      // a soft cue when Claude is about to compact the conversation
    var quietHours = false        // mute chimes and banners between quietStart and quietEnd
    var quietStart = "22:00"
    var quietEnd = "08:00"

    /// Minutes after midnight for an "HH:MM" string.
    static func minutes(_ hhmm: String) -> Int? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { return nil }
        return p[0] * 60 + p[1]
    }

    /// Whether `date` falls in quiet hours. Windows can wrap past midnight (22:00 to 08:00).
    func inQuietHours(_ date: Date = Date()) -> Bool {
        guard quietHours, let start = Config.minutes(quietStart), let end = Config.minutes(quietEnd), start != end else { return false }
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (now >= start && now < end) : (now >= start || now < end)
    }

    enum BannerPosition: String, CaseIterable, Identifiable {
        case topRight, topCenter, bottomRight
        var id: String { rawValue }
        var label: String {
            switch self {
            case .topRight: return "Top right"
            case .topCenter: return "Top center"
            case .bottomRight: return "Bottom right"
            }
        }
    }

    enum Badge: String, CaseIterable, Identifiable {
        case all, input, off
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: return "Needs input and finished"
            case .input: return "Needs input only"
            case .off: return "Off"
            }
        }
    }

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
            case "error": c.error = (v as NSString).expandingTildeInPath
            case "finishedMinSeconds": c.finishedMinSeconds = max(0, min(3600, Int(v) ?? c.finishedMinSeconds))
            case "reminderMinutes": c.reminderMinutes = max(0, min(240, Int(v) ?? c.reminderMinutes))
            case "quietHours": c.quietHours = on
            case "compactChime": c.compactChime = on
            case "quietStart": if Config.minutes(v) != nil { c.quietStart = v }
            case "quietEnd": if Config.minutes(v) != nil { c.quietEnd = v }
            case "volume": c.volume = min(1, max(0, Double(v) ?? c.volume))
            case "muted": c.muted = on
            case "badge": c.badge = Badge(rawValue: v) ?? c.badge
            case "showCount": if !on { c.badge = .off }   // 1.1 setting; replaced by badge
            case "showFinished": c.showFinished = on
            case "showWorking": c.showWorking = on
            case "banner": c.banner = Badge(rawValue: v) ?? c.banner
            case "bannerPosition": c.bannerPosition = BannerPosition(rawValue: v) ?? c.bannerPosition
            case "bannerSeconds": c.bannerSeconds = max(0, min(120, Int(v) ?? c.bannerSeconds))
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
        error=\(error)
        volume=\(String(format: "%.2f", volume))
        muted=\(muted ? 1 : 0)
        badge=\(badge.rawValue)
        showFinished=\(showFinished ? 1 : 0)
        showWorking=\(showWorking ? 1 : 0)
        banner=\(banner.rawValue)
        bannerPosition=\(bannerPosition.rawValue)
        bannerSeconds=\(bannerSeconds)
        finishedMinSeconds=\(finishedMinSeconds)
        reminderMinutes=\(reminderMinutes)
        compactChime=\(compactChime ? 1 : 0)
        quietHours=\(quietHours ? 1 : 0)
        quietStart=\(quietStart)
        quietEnd=\(quietEnd)

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
    for prefix in ["input-", "done-", "error-"] where name.hasPrefix(prefix) { name.removeFirst(prefix.count) }
    return name.replacingOccurrences(of: "-", with: " ").capitalized
}

// MARK: - Sessions waiting on you

struct SessionState: Codable, Identifiable {
    enum Status: String, Codable { case needsInput = "needs-input", finished, working }
    var id: String
    var status: Status
    var title: String
    var cwd: String
    var message: String?
    var appBundleID: String?   // the app the session runs in (Claude desktop, Terminal, iTerm, ...)
    var updatedAt: Date
    // Added in 1.3 (optional so older files still decode):
    var pid: Int32?            // the session's Claude Code process (CLAUDE_PID)
    var pidStart: Double?      // that process's start time, so a reused PID isn't mistaken for it
    var entrypoint: String?    // CLAUDE_CODE_ENTRYPOINT: "claude-desktop", "cli", ...
    var hostSessionID: String? // CLAUDE_CODE_HOST_SESSION_ID: the desktop app's chat ID ("local_…")
    // Added in 1.6:
    var workingSince: Date?    // when you last sent a message; the turn's start
    var turnSeconds: Double?   // how long the finished turn took
    var failed: Bool?          // the turn ended with an error (StopFailure)
    var transcriptPath: String?
    var tty: String?           // the Claude process's terminal, e.g. "/dev/ttys003" (CLI sessions only)
    var termProgram: String?   // TERM_PROGRAM: "Apple_Terminal", "iTerm.app", "vscode", ...

    var isFailed: Bool { failed == true }

    /// The Claude desktop app's link to this exact chat, when it runs in the desktop app.
    var desktopLink: URL? {
        // A CLI started from a terminal inside the desktop app inherits the host ID, so require the desktop entrypoint.
        guard entrypoint == "claude-desktop", let id = hostSessionID,
              id.range(of: #"^local_[A-Za-z0-9-]{1,64}$"#, options: .regularExpression) != nil
        else { return nil }
        return URL(string: "claude://code/continue?session=\(id)")
    }

    /// Whether the session can still be waiting on you, judged by its Claude process.
    /// A pending prompt dies with its process. A finished desktop session can be resumed after
    /// the app restarts its process, so only finished CLI sessions are dropped when the process exits.
    var isStale: Bool {
        guard let pid, !ProcessCheck.isAlive(pid: pid, startedAt: pidStart) else { return false }
        return status != .finished || entrypoint != "claude-desktop"
    }

    /// A "working" session whose turn ended without a Stop event (for example, you interrupted it):
    /// nothing has touched it or its transcript for half an hour.
    var isAbandonedWork: Bool {
        guard status == .working else { return false }
        let idle: TimeInterval = 30 * 60
        let lastTranscriptWrite = transcriptPath.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0))?[.modificationDate] as? Date
        } ?? updatedAt
        return Date().timeIntervalSince(max(updatedAt, lastTranscriptWrite)) > idle
    }
}

enum ProcessCheck {
    /// Start time of a running process (seconds since 1970), or nil if no such process exists.
    static func startTime(_ pid: Int32) -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }

    /// The controlling terminal of a process, such as "/dev/ttys003", or nil if it has none.
    static func tty(_ pid: Int32) -> String? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let dev = info.kp_eproc.e_tdev
        guard dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        let s = String(cString: name)
        return s.hasPrefix("tty") ? "/dev/" + s : nil
    }

    static func isAlive(pid: Int32, startedAt: Double?) -> Bool {
        guard let now = startTime(pid) else { return false }
        guard let startedAt else { return true }
        return abs(now - startedAt) < 2
    }
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

    /// All recorded sessions, newest first. Prunes entries older than a day, sessions whose
    /// Claude process has exited (see `isStale`), and unreadable files.
    static func all() -> [SessionState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil)) ?? []
        var out: [SessionState] = []
        for f in files where f.pathExtension == "json" {
            guard let d = try? Data(contentsOf: f), let s = try? decoder.decode(SessionState.self, from: d) else {
                // Half-written files are replaced atomically, so anything unreadable here is junk.
                if let age = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   Date().timeIntervalSince(age) > 60 { try? FileManager.default.removeItem(at: f) }
                continue
            }
            if Date().timeIntervalSince(s.updatedAt) > maxAge {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            if s.isStale || s.isAbandonedWork {
                try? FileManager.default.removeItem(at: f)
                EventLog.append("pruned session=\(s.id.prefix(8)) reason=\(s.isStale ? "process-exited" : "idle-working") status=\(s.status.rawValue)")
                continue
            }
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

// MARK: - Event log

/// A small rotating log of hook events (~/.claude/chimes/events.log) for diagnostics.
enum EventLog {
    static let url = chimesDir.appendingPathComponent("events.log")
    static let maxBytes = 256 * 1024

    static func append(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(message)\n".data(using: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: chimesDir, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes { rotate() }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    /// Keeps the newest half of the log.
    static func rotate() {
        guard let d = try? Data(contentsOf: url), d.count > maxBytes / 2 else { return }
        var tail = d.suffix(maxBytes / 2)
        if let nl = tail.firstIndex(of: UInt8(ascii: "\n")) { tail = tail[tail.index(after: nl)...] }
        try? Data(tail).write(to: url, options: .atomic)
    }

    static func tail(_ n: Int) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Array(text.split(separator: "\n").suffix(n).map(String.init))
    }

    static var lastWrite: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

// MARK: - Hook mode

/// Plays a sound with afplay, detached so the hook returns immediately.
func playDetached(_ path: String, volume: Double) {
    guard volume > 0 else { return }
    guard FileManager.default.fileExists(atPath: path) else {
        EventLog.append("warn sound-missing path=\(path)")
        return
    }
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
    let short = id.isEmpty ? "-" : String(id.prefix(8))
    let transcript = payload["transcript_path"] as? String

    @discardableResult
    func record(_ status: SessionState.Status, message: String?, workingSince: Date? = nil,
                turnSeconds: Double? = nil, failed: Bool = false, note: String = "") -> SessionState? {
        guard !id.isEmpty else { return nil }
        let previous = Sessions.read(id)
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let title = transcriptTitle(transcript) ?? previous?.title ?? (folder.isEmpty ? "Claude session" : folder)
        let pid = env["CLAUDE_PID"].flatMap { Int32($0) }
        let s = SessionState(id: id, status: status, title: title, cwd: cwd, message: message,
                             appBundleID: env["__CFBundleIdentifier"] ?? previous?.appBundleID, updatedAt: Date(),
                             pid: pid ?? previous?.pid, pidStart: pid.flatMap(ProcessCheck.startTime) ?? previous?.pidStart,
                             entrypoint: env["CLAUDE_CODE_ENTRYPOINT"] ?? previous?.entrypoint,
                             hostSessionID: env["CLAUDE_CODE_HOST_SESSION_ID"] ?? previous?.hostSessionID,
                             workingSince: workingSince, turnSeconds: turnSeconds, failed: failed ? true : nil,
                             transcriptPath: transcript ?? previous?.transcriptPath,
                             tty: pid.flatMap(ProcessCheck.tty) ?? previous?.tty,
                             termProgram: env["TERM_PROGRAM"] ?? previous?.termProgram)
        Sessions.write(s)
        EventLog.append("\(event) session=\(short) status=\(status.rawValue) title=\"\(title)\"\(note)")
        return s
    }

    /// Plays `path` unless muted or in quiet hours, and says which in the log line.
    func chime(_ path: String) -> String {
        if config.muted { return " chime=muted" }
        if config.inQuietHours() { return " chime=quiet-hours" }
        playDetached(path, volume: volume)
        return " chime=played"
    }

    switch event {
    case "prompt":
        // You sent a message: the session is working, and the turn's clock starts.
        record(.working, message: nil, workingSince: Date())
    case "notification":
        // Idle reminders arrive a minute after a reply finished; the Stop chime already covered that.
        let type = payload["notification_type"] as? String ?? ""
        if type == "idle_prompt" || type == "auth_success" {
            EventLog.append("notification session=\(short) type=\(type) skipped")
            exit(0)
        }
        record(.needsInput, message: payload["message"] as? String,
               workingSince: Sessions.read(id)?.workingSince, note: chime(config.input))
    case "tool":
        // A tool ran, so a pending permission prompt was answered and Claude is working again.
        // (Runs after every tool call, so it only writes when something changes.)
        if let prev = Sessions.read(id), prev.status == .needsInput {
            record(.working, message: nil, workingSince: prev.workingSince, note: " cleared needs-input")
        }
    case "stop":
        let started = Sessions.read(id)?.workingSince
        let turn = started.map { Date().timeIntervalSince($0) }
        let long = config.finishedMinSeconds == 0 || turn == nil || turn! >= Double(config.finishedMinSeconds)
        let note = (turn.map { " turn=\(Int($0))s" } ?? "") + (long ? chime(config.done) : " chime=skipped-short-turn")
        record(.finished, message: nil, turnSeconds: turn, note: note)
    case "failure":
        // The turn ended with an error (Claude Code's StopFailure hook).
        let started = Sessions.read(id)?.workingSince
        let reason = (payload["error"] as? String) ?? (payload["message"] as? String) ?? (payload["reason"] as? String)
        record(.finished, message: reason ?? "Claude hit an error", turnSeconds: started.map { Date().timeIntervalSince($0) },
               failed: true, note: chime(config.error))
    case "compact":
        // Optional cue: compaction summarizes earlier context, so it's worth a glance afterwards.
        EventLog.append("compact session=\(short)\(config.compactChime ? chime(config.input) : " chime=off")")
    case "end":
        if Sessions.read(id) != nil { Sessions.remove(id) }
        EventLog.append("end session=\(short) cleared")
    default:
        EventLog.append("warn unknown-event \(event)")
    }
    exit(0)
}

// MARK: - Health check and repair

struct HealthCheck: Identifiable {
    enum Level: Int { case ok, warn, fail }
    let id: String
    let level: Level
    let title: String
    let detail: String
}

enum Health {
    static var hookLink: URL { Installer.hookLink }
    static var appBinary: URL? { Installer.appBinary }

    static func run(config: Config) -> [HealthCheck] {
        var out: [HealthCheck] = []
        switch Installer.readSettings() {
        case .failure(let error):
            out.append(.init(id: "settings", level: .fail, title: "Claude Code settings", detail: error.message))
        case .success(let settings):
            if settings["disableAllHooks"]?.bool == true {
                out.append(.init(id: "disabled", level: .fail, title: "Hooks are turned off",
                                 detail: "\"disableAllHooks\" is true in ~/.claude/settings.json, so no chimes will play."))
            }
            let missing = Installer.wanted.filter { ev, arg, _ in
                !Installer.commands(in: settings, event: ev).contains { $0.contains("chimes/chime-hook \(arg)") }
            }.map(\.0)
            out.append(missing.isEmpty
                ? .init(id: "hooks", level: .ok, title: "Claude Code hooks", detail: "All \(Installer.wanted.count) hooks are installed.")
                : .init(id: "hooks", level: .fail, title: "Claude Code hooks", detail: "Missing: \(missing.joined(separator: ", ")). Repair adds them back."))
        }

        let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: hookLink.path))
            .map { URL(fileURLWithPath: $0, relativeTo: chimesDir).resolvingSymlinksInPath() }
        if target == nil || !FileManager.default.isExecutableFile(atPath: hookLink.path) {
            out.append(.init(id: "link", level: .fail, title: "Hook link",
                             detail: "~/.claude/chimes/chime-hook is missing or broken. Repair relinks it to this app."))
        } else if let app = appBinary, target?.path != app.path, appBundle.bundleURL.pathExtension == "app" {
            out.append(.init(id: "link", level: .warn, title: "Hook link",
                             detail: "Points at a different copy of the app (\(target!.path)). Repair points it here."))
        } else {
            out.append(.init(id: "link", level: .ok, title: "Hook link", detail: "~/.claude/chimes/chime-hook → this app"))
        }

        let missingSounds = [config.input, config.done].filter { !FileManager.default.fileExists(atPath: $0) }
        out.append(missingSounds.isEmpty
            ? .init(id: "sounds", level: .ok, title: "Sound files", detail: "Both chosen sounds are on disk.")
            : .init(id: "sounds", level: .fail, title: "Sound files",
                    detail: "Not found: \(missingSounds.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")). Pick another sound."))

        if config.muted || config.volume == 0 {
            out.append(.init(id: "volume", level: .warn, title: "Volume",
                             detail: config.muted ? "Chimes are muted." : "Volume is at 0%, so chimes are silent."))
        }

        if let last = EventLog.lastWrite {
            let f = RelativeDateTimeFormatter()
            out.append(.init(id: "events", level: .ok, title: "Last hook event",
                             detail: Date().timeIntervalSince(last) < 45 ? "Just now" : f.localizedString(for: last, relativeTo: Date()).capitalizedFirst))
        } else {
            out.append(.init(id: "events", level: .warn, title: "Last hook event",
                             detail: "None yet. Sessions that were already open need a restart to load the hooks."))
        }
        return out
    }

    /// Relinks chime-hook, re-adds the hooks and restores any missing bundled sounds.
    static func repair() throws { try Installer.install() }

    /// Quietly fixes the hook link at launch (for example after the app was moved).
    /// Never touches settings.json without the user asking.
    static func relinkIfNeeded() {
        guard appBundle.bundleURL.pathExtension == "app", let app = appBinary else { return }
        let current = (try? FileManager.default.destinationOfSymbolicLink(atPath: hookLink.path))
            .map { URL(fileURLWithPath: $0, relativeTo: chimesDir).resolvingSymlinksInPath().path }
        guard current != app.path else { return }
        try? FileManager.default.createDirectory(at: chimesDir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: hookLink)
        if (try? FileManager.default.createSymbolicLink(at: hookLink, withDestinationURL: app)) != nil {
            EventLog.append("relinked chime-hook -> \(app.path)")
        }
    }

    static func diagnostics(config: Config, checks: [HealthCheck], sessions: [SessionState]) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = ["Claude Chimes \(appVersion) on macOS \(os) (\(machineArch()))",
                     "App: \(appBundle.bundlePath)", "", "Health:"]
        let mark = ["ok", "WARN", "FAIL"]
        lines += checks.map { "  [\(mark[$0.level.rawValue])] \($0.title): \($0.detail)" }
        lines += ["", "Config:"]
        lines += ((try? String(contentsOf: configURL, encoding: .utf8)) ?? "(missing)")
            .split(separator: "\n").filter { !$0.hasPrefix("#") }.map { "  \($0)" }
        lines += ["", "Sessions: \(sessions.filter { $0.status == .needsInput }.count) need input, \(sessions.filter { $0.status == .finished }.count) finished"]
        lines += ["", "Recent events:"] + EventLog.tail(40).map { "  \($0)" }
        return lines.joined(separator: "\n")
    }

    static func machineArch() -> String {
        var sys = utsname(); uname(&sys)
        return withUnsafeBytes(of: &sys.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

extension DateFormatter {
    static let backupStamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyyMMddHHmmss"; return f }()
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Shared model

@MainActor
final class AppModel: ObservableObject {
    @Published var config = Config.load() {
        didSet { if config != oldValue { config.save(); onChange?() } }
    }
    @Published var sessions: [SessionState] = []
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var health: [HealthCheck] = []
    @Published var repairMessage: String?
    var onChange: (() -> Void)?
    private var player: NSSound?

    var needsInput: [SessionState] { sessions.filter { $0.status == .needsInput } }
    var finished: [SessionState] { sessions.filter { $0.status == .finished } }
    var working: [SessionState] { sessions.filter { $0.status == .working } }
    var hasHealthFailure: Bool { health.contains { $0.level == .fail } }

    var needsRepair: Bool { health.contains { $0.level == .fail || ($0.level == .warn && $0.id == "link") } }

    func refreshHealth() {
        health = Health.run(config: config)
        onChange?()
    }

    /// Shows a short status line under the Health buttons, then clears it.
    func flash(_ message: String, seconds: Double = 4) {
        repairMessage = message
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            if self?.repairMessage == shown { self?.repairMessage = nil }
        }
    }

    func recheck() {
        refreshHealth()
        let issues = health.filter { $0.level != .ok }.count
        flash(issues == 0 ? "All checks passed." : "\(issues) issue\(issues == 1 ? "" : "s") found.")
    }

    func repair() {
        do {
            try Health.repair()
            refreshHealth()
            flash("Repaired. Restart open Claude sessions to load the hooks.", seconds: 6)
        } catch {
            refreshHealth()
            flash("Repair failed: \(error.localizedDescription)", seconds: 8)
        }
    }

    func copyDiagnostics() {
        refreshHealth()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Health.diagnostics(config: config, checks: health, sessions: sessions), forType: .string)
        flash("Diagnostics copied to the clipboard.")
    }

    var onSessionsChanged: ((_ old: [SessionState], _ new: [SessionState]) -> Void)?
    var onTestBanner: (() -> Void)?

    func reloadSessions() {
        let old = sessions
        sessions = Sessions.all()
        onSessionsChanged?(old, sessions)
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
            // Preview from the setter, so reloading the config from disk never plays a sound.
            Picker(title, selection: Binding(get: { path }, set: { path = $0; model.preview($0) })) {
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
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var height: CGFloat = 760

    /// Binds a DatePicker to an "HH:MM" config string.
    func timeBinding(_ key: WritableKeyPath<Config, String>) -> Binding<Date> {
        Binding(
            get: {
                let m = Config.minutes(model.config[keyPath: key]) ?? 0
                return Calendar.current.date(bySettingHour: m / 60, minute: m % 60, second: 0, of: Date()) ?? Date()
            },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                model.config[keyPath: key] = String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
            })
    }

    var body: some View {
        Form {
            Section("Sounds") {
                SoundRow(title: "Needs input", detail: "Permission prompts and questions",
                         key: "input", path: $model.config.input, model: model)
                SoundRow(title: "Finished", detail: "Claude finished a reply",
                         key: "done", path: $model.config.done, model: model)
                SoundRow(title: "Turn failed", detail: "A turn ended with an error",
                         key: "error", path: $model.config.error, model: model)
            }

            Section("When to Chime") {
                Picker("Chime when Claude finishes", selection: $model.config.finishedMinSeconds) {
                    Text("After every reply").tag(0)
                    Text("After 15 seconds of work").tag(15)
                    Text("After 30 seconds of work").tag(30)
                    Text("After 1 minute of work").tag(60)
                    Text("After 2 minutes of work").tag(120)
                    Text("After 5 minutes of work").tag(300)
                }
                Text("Quick replies stay silent, so you only hear Finished when Claude has been working a while. Banners follow the same rule.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Remind me about an unanswered prompt", selection: $model.config.reminderMinutes) {
                    Text("Off").tag(0)
                    Text("After 2 minutes").tag(2)
                    Text("After 5 minutes").tag(5)
                    Text("After 10 minutes").tag(10)
                    Text("After 15 minutes").tag(15)
                }
                Toggle("Chime before Claude compacts the conversation", isOn: $model.config.compactChime)
                Toggle("Quiet hours", isOn: $model.config.quietHours)
                if model.config.quietHours {
                    HStack {
                        DatePicker("From", selection: timeBinding(\.quietStart), displayedComponents: .hourAndMinute)
                        DatePicker("to", selection: timeBinding(\.quietEnd), displayedComponents: .hourAndMinute)
                    }
                    Text("Chimes and banners stay quiet in this window. Sessions are still tracked in the menu.")
                        .font(.caption).foregroundStyle(.secondary)
                }
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
                Picker("Badge on icon", selection: $model.config.badge) {
                    ForEach(Config.Badge.allCases) { Text($0.label).tag($0) }
                }
                Text("Red when a session needs your input, gray when sessions are only waiting for your reply.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("List sessions ready for your reply", isOn: $model.config.showFinished)
                Toggle("List sessions Claude is working on", isOn: $model.config.showWorking)
            }

            Section("Banners") {
                Picker("Show a banner for", selection: $model.config.banner) {
                    ForEach(Config.Badge.allCases) { Text($0.label).tag($0) }
                }
                Picker("Position", selection: $model.config.bannerPosition) {
                    ForEach(Config.BannerPosition.allCases) { Text($0.label).tag($0) }
                }
                Picker("Hide after", selection: $model.config.bannerSeconds) {
                    Text("4 seconds").tag(4)
                    Text("8 seconds").tag(8)
                    Text("15 seconds").tag(15)
                    Text("Until dismissed").tag(0)
                }
                .disabled(model.config.banner == .off)
                HStack {
                    Text("A banner names the session and what it's waiting for. Click it to open the session, or × to dismiss it.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Show Test Banner") { model.onTestBanner?() }
                        .disabled(model.config.banner == .off)
                }
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
                LabeledContent("Remove Claude Chimes") {
                    Button("Uninstall…", role: .destructive) { Uninstall.run() }
                }
            }

            Section("Health") {
                ForEach(model.health) { check in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ["checkmark.circle.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill"][check.level.rawValue])
                            .foregroundStyle([Color.green, Color.orange, Color.red][check.level.rawValue])
                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.title)
                            Text(check.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    Button("Repair") { model.repair() }
                        .disabled(!model.needsRepair)
                        .help("Relink chime-hook to this app and re-add the Claude Code hooks (backs up settings.json first)")
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                    Button("Show Log") {
                        if !FileManager.default.fileExists(atPath: EventLog.url.path) { EventLog.append("log opened") }
                        NSWorkspace.shared.activateFileViewerSelecting([EventLog.url])
                    }
                    Spacer()
                    Button { model.recheck() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Check again")
                }
                if let msg = model.repairMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { model.refreshHealth() }

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
        .frame(width: 500, height: height)
    }
}

// MARK: - Menu bar

enum StatusIcon {
    /// Menu bar icon from the app bundle (Resources/menubar.svg, menubar-muted.svg) as a template image.
    static func image(muted: Bool) -> NSImage? {
        let name = muted ? "menubar-muted" : "menubar"
        let img = appBundle.url(forResource: name, withExtension: "svg").flatMap { NSImage(contentsOf: $0) }
            ?? NSImage(systemSymbolName: muted ? "speaker.slash" : "waveform", accessibilityDescription: nil)
        img?.size = NSSize(width: 18, height: 18)
        img?.isTemplate = true
        img?.accessibilityDescription = "Claude Chimes"
        return img
    }

    /// The icon with a number badge in its top-right corner: red when something needs your input,
    /// gray when sessions are only waiting for your reply. Count 0 returns the plain template icon.
    /// Drawn on demand, so the icon follows the menu bar's light/dark appearance.
    static func image(muted: Bool, count: Int, urgent: Bool) -> NSImage? {
        guard count > 0, let base = image(muted: muted) else { return image(muted: muted) }
        let text = count > 9 ? "9+" : "\(count)"
        let font = NSFont.systemFont(ofSize: 9, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let badgeH: CGFloat = 12
        let badgeW = max(badgeH, ceil(textSize.width) + 6)
        let size = NSSize(width: 20 + badgeW, height: 18)

        let img = NSImage(size: size, flipped: false) { _ in
            // Icon, tinted with the menu bar's text color.
            let iconRect = NSRect(x: 0, y: 0, width: 18, height: 18)
            let icon = NSImage(size: iconRect.size, flipped: false) { r in
                base.draw(in: r)
                NSColor.labelColor.set()
                r.fill(using: .sourceAtop)
                return true
            }
            icon.draw(in: iconRect)

            // Badge: a small pill beside the icon, vertically centered.
            let badge = NSRect(x: size.width - badgeW, y: (size.height - badgeH) / 2, width: badgeW, height: badgeH)
            (urgent ? NSColor.systemRed : NSColor.systemGray).setFill()
            NSBezierPath(roundedRect: badge, xRadius: badgeH / 2, yRadius: badgeH / 2).fill()
            (text as NSString).draw(at: NSPoint(x: badge.midX - textSize.width / 2, y: badge.midY - textSize.height / 2),
                                    withAttributes: attrs)
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Claude Chimes, \(count) waiting"
        return img
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    let banners = BannerCenter()
    var statusItem: NSStatusItem!
    var settingsWindow: NSWindow?
    var welcomeWindow: NSWindow?
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
        // Restore the bundled chimes if the sounds folder is gone (a fresh download, or it was deleted).
        if soundFiles(in: soundsDir).isEmpty { Installer.seedSounds() }
        model.onChange = { [weak self] in self?.updateStatusButton() }
        banners.config = { [weak self] in self?.model.config ?? Config.load() }
        banners.onOpen = { [weak self] s in self?.open(s) }
        banners.onDismiss = { [weak self] s in if s.id != "test-banner" { self?.dismiss(s, in: nil) } }
        model.onTestBanner = { [weak self] in self?.showTestBanner() }
        // Sessions already waiting at launch are the baseline: no burst of banners on startup.
        model.reloadSessions()
        model.onSessionsChanged = { [weak self] old, new in self?.sessionsChanged(old: old, new: new) }
        Health.relinkIfNeeded()
        Installer.upgradeIfNeeded()
        if Welcome.shouldShow { showWelcome() }
        watchSessions()
        model.reloadSessions()
        model.refreshHealth()
        // Pick up edits made outside the app, age out old or exited sessions, and recheck health.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.model.reloadConfig()
                self?.model.reloadSessions()
                self?.model.refreshHealth()
                self?.remindAboutUnansweredPrompts()
            }
        }
    }

    func watchSessions() {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
        let fd = Darwin.open(sessionsDir.path, O_EVTONLY)
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
        let needs = model.needsInput.count, finished = model.finished.count
        let count: Int
        switch c.badge {
        case .all: count = needs + finished
        case .input: count = needs
        case .off: count = 0
        }
        button.image = StatusIcon.image(muted: c.muted || c.volume == 0, count: count, urgent: needs > 0)
        button.title = ""
        var parts: [String] = []
        if model.hasHealthFailure { parts.append("setup needs attention") }
        if needs > 0 { parts.append("\(needs) need\(needs == 1 ? "s" : "") your input") }
        if finished > 0 { parts.append("\(finished) ready for your reply") }
        button.toolTip = parts.isEmpty ? "Claude Chimes" : "Claude Chimes: " + parts.joined(separator: ", ")
    }

    // The menu's own highlight drives the session rows, so exactly one row (or none) is highlighted.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        SessionRowView.highlight(item?.view as? SessionRowView)
    }

    func menuDidClose(_ menu: NSMenu) {
        SessionRowView.highlight(nil)
    }

    // Rebuilt each time the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        model.reloadConfig()
        model.reloadSessions()
        model.refreshHealth()
        build(menu)
    }

    /// Fills the menu from the model. Also called while the menu is open, after a session is dismissed.
    func build(_ menu: NSMenu) {
        menu.removeAllItems()

        let needs = model.needsInput
        let finished = model.config.showFinished ? model.finished : []

        if model.hasHealthFailure {
            let warn = item("Setup needs attention…", #selector(openSettings))
            warn.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            let first = model.health.first { $0.level == .fail }
            if #available(macOS 14.4, *) { warn.subtitle = first.map { "\($0.title): open Settings to repair" } }
            menu.addItem(warn)
            menu.addItem(.separator())
        }

        let anyWorking = model.config.showWorking && !model.working.isEmpty
        if needs.isEmpty && finished.isEmpty && !anyWorking {
            let none = NSMenuItem(title: "Nothing waiting on you", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        if !needs.isEmpty { menu.addItem(NSMenuItem.sectionHeader(title: "Needs Your Input")) }
        for s in needs.prefix(10) {
            menu.addItem(sessionItem(s, symbol: "exclamationmark.bubble.fill", tint: .systemRed,
                                     detail: [s.message, ago(s.updatedAt)].compactMap { $0 }.joined(separator: " · ")))
        }

        if !finished.isEmpty {
            if !needs.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: "Ready for Your Reply"))
            for s in finished.prefix(10) {
                menu.addItem(s.isFailed
                    ? sessionItem(s, symbol: "exclamationmark.triangle", tint: .systemOrange,
                                  detail: "Failed \(ago(s.updatedAt))" + (s.message.map { " · \($0)" } ?? ""))
                    : sessionItem(s, symbol: "checkmark.bubble", detail: "Finished \(ago(s.updatedAt))"))
            }
            menu.addItem(item("Clear Finished", #selector(clearFinished)))
        }

        // Working: what Claude is busy on right now, longest-running first. Nothing to act on, so it goes last.
        let working = model.config.showWorking
            ? model.working.sorted { ($0.workingSince ?? $0.updatedAt) < ($1.workingSince ?? $1.updatedAt) } : []
        if !working.isEmpty {
            if !needs.isEmpty || !finished.isEmpty { menu.addItem(.separator()) }
            menu.addItem(NSMenuItem.sectionHeader(title: "Working"))
            for s in working.prefix(10) {
                let since = s.workingSince ?? s.updatedAt
                let elapsed = Date().timeIntervalSince(since)
                menu.addItem(sessionItem(s, symbol: "ellipsis.bubble",
                                         detail: elapsed < 45 ? "Working · started just now" : "Working for \(BannerView.duration(elapsed))"))
            }
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

    /// A session row: click to open it, or click its × to dismiss it when you're done.
    func sessionItem(_ s: SessionState, symbol: String, tint: NSColor = .secondaryLabelColor, detail: String) -> NSMenuItem {
        let i = NSMenuItem(title: s.title, action: nil, keyEquivalent: "")
        i.representedObject = s
        i.toolTip = s.cwd
        i.view = SessionRowView(title: s.title, subtitle: detail, symbol: symbol, iconTint: tint,
                                onOpen: { [weak self] in self?.open(s) },
                                onDismiss: { [weak self, weak i] in self?.dismiss(s, in: i?.menu) })
        return i
    }

    /// Removes one session from the list (you're done with it) and redraws the open menu.
    /// Shows a banner for each session that newly needs you or just finished, and removes banners
    /// for sessions that no longer wait on you.
    func sessionsChanged(old: [SessionState], new: [SessionState]) {
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let c = model.config
        for s in new {
            let prev = before[s.id]
            let isNews = prev == nil || prev!.status != s.status || s.updatedAt.timeIntervalSince(prev!.updatedAt) > 0.5
            guard isNews else { continue }
            if s.status == .working { banners.remove(id: s.id, animated: true); continue }
            // Same rule as the Finished chime: short turns stay quiet unless they failed.
            let shortTurn = s.status == .finished && !s.isFailed && c.finishedMinSeconds > 0
                && (s.turnSeconds ?? .infinity) < Double(c.finishedMinSeconds)
            let wanted = !c.inQuietHours() && !shortTurn
                && (c.banner == .all || (c.banner == .input && (s.status == .needsInput || s.isFailed)))
            if wanted { banners.show(s) } else { banners.remove(id: s.id, animated: true) }
        }
        let alive = Set(new.map(\.id))
        for id in banners.visibleIDs where !alive.contains(id) && id != "test-banner" { banners.remove(id: id, animated: true) }
    }

    /// Keys ("id@updatedAt") of prompts already reminded about, so each gets one reminder.
    var reminded: Set<String> = []

    /// Chimes and shows a banner once for a prompt left unanswered for `reminderMinutes`.
    func remindAboutUnansweredPrompts() {
        let c = model.config
        guard c.reminderMinutes > 0, !c.muted, !c.inQuietHours() else { return }
        for s in model.needsInput where Date().timeIntervalSince(s.updatedAt) >= Double(c.reminderMinutes * 60) {
            let key = "\(s.id)@\(s.updatedAt.timeIntervalSince1970)"
            guard !reminded.contains(key) else { continue }
            reminded.insert(key)
            model.preview(c.input)
            if c.banner != .off { banners.show(s) }
            EventLog.append("remind session=\(s.id.prefix(8)) after=\(c.reminderMinutes)m")
        }
    }

    /// A sample banner for Settings → Banners → Show Test Banner.
    func showTestBanner() {
        banners.show(SessionState(id: "test-banner", status: .needsInput, title: "Test banner from Claude Chimes",
                                  cwd: "", message: "This is what a banner looks like", appBundleID: nil, updatedAt: Date()))
    }

    func dismiss(_ s: SessionState, in menu: NSMenu?) {
        Sessions.remove(s.id)
        EventLog.append("dismiss session=\(s.id.prefix(8)) status=\(s.status.rawValue)")
        model.reloadSessions()
        if let menu { build(menu) }
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

    /// Opens the session: desktop chats open directly via the Claude app's `claude://code/continue` link;
    /// CLI sessions (and older entries without a desktop ID) bring their app to the front.
    func open(_ s: SessionState) {
        if let link = s.desktopLink, NSWorkspace.shared.open(link) {
            EventLog.append("open session=\(s.id.prefix(8)) via=desktop-link")
            return
        }
        if TerminalJump.focus(s) {
            EventLog.append("open session=\(s.id.prefix(8)) via=terminal-tab")
            return
        }
        let bundleID = s.appBundleID ?? TerminalJump.bundleID(for: s.termProgram) ?? "com.anthropic.claudefordesktop"
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            running.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
        }
    }

    func showWelcome() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Welcome to Claude Chimes"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: WelcomeView(
            onSetUp: { [weak self] in
                try Installer.install()
                self?.model.reloadConfig()
                self?.model.refreshHealth()
            },
            onClose: { [weak self] skipped in
                if skipped { UserDefaults.standard.set(true, forKey: Welcome.skippedKey) }
                self?.welcomeWindow?.close()
                self?.welcomeWindow = nil
            }))
        w.center()
        welcomeWindow = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 760),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Claude Chimes Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView(model: model))
            w.center()
            w.setFrameAutosaveName("ClaudeChimesSettings")
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
// (A `--flag` argument skips hook mode, so `chime-hook --doctor` works too.)
if URL(fileURLWithPath: args[0]).lastPathComponent == "chime-hook", !(args.count > 1 && args[1].hasPrefix("--")) {
    runHook(args.count > 1 ? args[1] : "")
}
if let i = args.firstIndex(of: "--hook") {
    runHook(i + 1 < args.count ? args[i + 1] : "")
}
// Command-line helpers (also handy when filing an issue):
//   --setup           copy the chimes, link chime-hook to this binary and add the hooks (install.sh runs this)
//   --repair          same as --setup
//   --uninstall       remove the hooks, the link and session state (add --delete-data to remove sounds and config)
//   --doctor          print the health check; exits 1 if anything fails
//   --list-sessions   print the sessions currently waiting on you (pruning stale ones)
//   --dismiss <id>    remove one session from the list (the full ID, or a unique prefix of it)
if args.contains("--doctor") {
    let checks = Health.run(config: Config.load())
    print(Health.diagnostics(config: Config.load(), checks: checks, sessions: Sessions.all()))
    exit(checks.contains { $0.level == .fail } ? 1 : 0)
}
if args.contains("--setup") || args.contains("--repair") {
    do { try Installer.install(); print("Claude Chimes is set up. Restart open Claude sessions to load the hooks.") }
    catch { FileHandle.standardError.write(Data("Setup failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    exit(0)
}
if args.contains("--uninstall") {
    do { try Installer.uninstall(deleteData: args.contains("--delete-data")); print("Claude Chimes hooks removed.") }
    catch { FileHandle.standardError.write(Data("Uninstall failed: \(error.localizedDescription)\n".utf8)); exit(1) }
    exit(0)
}
if let i = args.firstIndex(of: "--dismiss") {
    let wanted = i + 1 < args.count ? args[i + 1] : ""
    let matches = Sessions.all().filter { !wanted.isEmpty && $0.id.hasPrefix(wanted) }
    guard matches.count == 1, let s = matches.first else {
        FileHandle.standardError.write(Data("\(matches.isEmpty ? "No session matches" : "More than one session matches") '\(wanted)'.\n".utf8))
        exit(1)
    }
    Sessions.remove(s.id)
    EventLog.append("dismiss session=\(s.id.prefix(8)) status=\(s.status.rawValue) via=cli")
    print("Dismissed \(s.title)")
    exit(0)
}
if args.contains("--list-sessions") {
    for s in Sessions.all() {
        print("\(s.status.rawValue)\t\(s.id.prefix(8))\tpid=\(s.pid.map(String.init) ?? "-")\t\(s.entrypoint ?? "-")\t\(s.title)\t\(s.desktopLink?.absoluteString ?? "-")\t\(s.tty ?? "-")")
    }
    exit(0)
}

// Used by uninstall.sh to remove the login item before the app is deleted.
if args.contains("--disable-login-item") {
    try? SMAppService.mainApp.unregister()
    exit(0)
}

// `ClaudeChimes --render-app-icon dir.iconset` writes the app icon at every size (see AppIcon.swift).
if let i = args.firstIndex(of: "--render-app-icon"), i + 1 < args.count {
    AppIcon.renderIconset(to: args[i + 1])
    exit(0)
}

// `ClaudeChimes --snapshot-icons out.png` renders the menu bar icon's badge states on light and dark bars.
if let i = args.firstIndex(of: "--snapshot-icons"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let states: [(Bool, Int, Bool)] = [(false, 0, false), (false, 2, false), (false, 1, true), (false, 3, true), (false, 12, true), (true, 2, true)]
        let cellW: CGFloat = 44, rowH: CGFloat = 28, scale: CGFloat = 4
        let W = cellW * CGFloat(states.count), H = rowH * 2
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: W, height: H)
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let appearance = NSAppearance(named: name)!
            appearance.performAsCurrentDrawingAppearance {
                let y = H - rowH * CGFloat(row + 1)
                (row == 0 ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.12, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: W, height: rowH).fill()
                for (col, s) in states.enumerated() {
                    guard let img = StatusIcon.image(muted: s.0, count: s.1, urgent: s.2) else { continue }
                    let drawn = img.isTemplate ? NSImage(size: img.size, flipped: false) { r in
                        img.draw(in: r); NSColor.labelColor.set(); r.fill(using: .sourceAtop); return true } : img
                    drawn.draw(in: NSRect(x: CGFloat(col) * cellW + (cellW - img.size.width) / 2,
                                          y: y + (rowH - img.size.height) / 2, width: img.size.width, height: img.size.height))
                }
            }
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    }
    exit(0)
}

// `ClaudeChimes --snapshot-welcome out.png [--done]` renders the first-run welcome window.
if let i = args.firstIndex(of: "--snapshot-welcome"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let m = WelcomeModel()
        if args.contains("--done") { m.step = .done }
        let view = NSHostingView(rootView: WelcomeView(model: m, onSetUp: {}, onClose: { _ in })
            .background(Color(nsColor: .windowBackgroundColor)))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
        }
    }
    exit(0)
}

// `ClaudeChimes --snapshot-rows out.png [--dark]` renders session rows (one hovered) as they look in the menu.
if let i = args.firstIndex(of: "--snapshot-rows"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let dark = args.contains("--dark")
        let rows = [
            SessionRowView(title: "Fix the login redirect", subtitle: "Claude needs your permission to use Bash · just now",
                           symbol: "exclamationmark.bubble.fill", iconTint: .systemRed, onOpen: {}, onDismiss: {}),
            SessionRowView(title: "Write the release notes", subtitle: "Finished 4 min ago", symbol: "checkmark.bubble", onOpen: {}, onDismiss: {}),
            SessionRowView(title: "Refactor the settings parser", subtitle: "Finished 12 min ago", symbol: "checkmark.bubble", onOpen: {}, onDismiss: {}),
        ]
        let w: CGFloat = 320, h = CGFloat(rows.count) * SessionRowView.height + 12
        let panel = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        for (n, r) in rows.enumerated() {
            r.frame = NSRect(x: 0, y: h - 6 - CGFloat(n + 1) * SessionRowView.height, width: w, height: SessionRowView.height)
            r.setHovering(n == 1)
            panel.addSubview(r)
        }
        let window = NSWindow(contentRect: panel.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.96, alpha: 1)
        window.contentView = panel
        panel.wantsLayer = true
        panel.layer?.backgroundColor = window.backgroundColor.cgColor
        panel.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.appearance!.performAsCurrentDrawingAppearance {
            if let rep = panel.bitmapImageRepForCachingDisplay(in: panel.bounds) {
                panel.cacheDisplay(in: panel.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
        }
    }
    exit(0)
}

// `ClaudeChimes --snapshot-banner out.png [--dark] [--finished]` renders a banner on a sample desktop color.
if let i = args.firstIndex(of: "--snapshot-banner"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let dark = args.contains("--dark"), finished = args.contains("--finished")
        let s = SessionState(id: "demo", status: finished ? .finished : .needsInput,
                             title: finished ? "Write the release notes" : "Fix the login redirect", cwd: "",
                             message: finished ? nil : "Claude needs your permission to use Bash", appBundleID: nil, updatedAt: Date())
        let pad: CGFloat = 20
        let canvas = NSView(frame: NSRect(x: 0, y: 0, width: BannerView.size.width + 2 * pad, height: BannerView.size.height + 2 * pad))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = (dark ? NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.2, alpha: 1)
                                              : NSColor(calibratedRed: 0.78, green: 0.83, blue: 0.9, alpha: 1)).cgColor
        let banner = BannerView(session: s, onOpen: {}, onDismiss: {})
        banner.frame.origin = NSPoint(x: pad, y: pad)
        // Offscreen rendering can't sample the desktop for the blur, so stand in with the material's tint.
        banner.wantsLayer = true
        banner.layer?.cornerRadius = 14
        banner.layer?.backgroundColor = (dark ? NSColor(white: 0.2, alpha: 0.92) : NSColor(white: 0.97, alpha: 0.92)).cgColor
        canvas.addSubview(banner)
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = canvas
        canvas.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        window.appearance!.performAsCurrentDrawingAppearance {
            if let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
            }
        }
    }
    exit(0)
}

// `ClaudeChimes --snapshot-settings out.png` renders the Settings window to a PNG (for docs and checks).
if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        let view = NSHostingView(rootView: SettingsView(model: AppModel(), height: 1500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 1500),
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
