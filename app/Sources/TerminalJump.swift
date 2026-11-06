// Brings a CLI session's exact terminal tab to the front, matched by the TTY its Claude
// process runs on. Terminal and iTerm2 expose each tab's TTY over AppleScript; other
// terminals fall back to activating the app. macOS asks once for permission to control
// the terminal (NSAppleEventsUsageDescription). Because the app is ad-hoc signed, a rebuild
// can make macOS ask again.

import AppKit

@MainActor
enum TerminalJump {
    static let terminal = "com.apple.Terminal"
    static let iTerm = "com.googlecode.iterm2"

    static func bundleID(for termProgram: String?) -> String? {
        switch termProgram {
        case "Apple_Terminal": return terminal
        case "iTerm.app": return iTerm
        case "vscode": return "com.microsoft.VSCode"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        default: return nil
        }
    }

    /// Selects the tab running `s` in Terminal or iTerm2. Returns false when there's no TTY,
    /// the terminal isn't one of those two, the tab is gone, or permission was refused.
    static func focus(_ s: SessionState) -> Bool {
        guard let tty = s.tty, tty.range(of: #"^/dev/ttys?[0-9]+$"#, options: .regularExpression) != nil else { return false }
        let app = [s.appBundleID, bundleID(for: s.termProgram)].compactMap { $0 }.first { $0 == terminal || $0 == iTerm }
        guard let app, !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty else { return false }

        let source = app == terminal ? """
            tell application id "\(terminal)"
              repeat with w in windows
                repeat with t in tabs of w
                  if tty of t is "\(tty)" then
                    set selected of t to true
                    set index of w to 1
                    activate
                    return true
                  end if
                end repeat
              end repeat
            end tell
            return false
            """ : """
            tell application id "\(iTerm)"
              repeat with w in windows
                repeat with t in tabs of w
                  repeat with ss in sessions of t
                    if tty of ss is "\(tty)" then
                      select w
                      tell t to select
                      tell ss to select
                      activate
                      return true
                    end if
                  end repeat
                end repeat
              end repeat
            end tell
            return false
            """
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { EventLog.append("warn terminal-jump \(app) error=\(error[NSAppleScript.errorNumber] ?? "?")") }
        return result?.booleanValue == true
    }
}
