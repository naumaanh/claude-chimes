# claude-chimes

Custom notification sounds for Claude, with a minimal macOS menu bar app to pick sounds and set the volume.

Claude Chimes plays a soft chime when Claude needs your input (a permission prompt or a question) and another when it finishes a reply. It works anywhere Claude Code runs on your Mac: the Code tab of the Claude desktop app, and the `claude` CLI in your terminal. Regular chats in the desktop app or on claude.ai don't run Claude Code hooks, so they don't trigger it.

> Unofficial community project. Not made by, endorsed by, or affiliated with Anthropic.

<p>
  <img src="docs/menu-bar-badges.png" alt="The menu bar icon with no badge, a gray badge, red badges, and muted" width="520">
</p>

## Features

The six chimes are synthesized on your Mac by a small Python script, so nothing is downloaded:

| Needs input | Finished |
| --- | --- |
| Nudge: two soft marimba notes, rising | Spark: a quick sparkle into a warm chord |
| Query: three glassy bell notes, unresolved | Settle: three descending kalimba notes |
| Knock: two muted wooden taps | Bloom: a slow, warm chord that rings out |

The menu bar lists the sessions waiting on you. Some need your input, with the question they're asking; others have finished and are ready for your reply. A badge next to the icon counts them, red when something needs you and gray when sessions are only waiting for a reply. Clicking a desktop-app chat opens it, and clicking a CLI session brings your terminal to the front.

The menu also has volume and mute. Everything else lives in a Settings window, where you can pick each sound from the bundled chimes, your own files or the macOS sounds, preview it, and check that the setup is healthy. To add your own sounds, drop any `.wav`, `.aiff`, `.mp3`, `.m4a` or `.caf` file into `~/.claude/chimes/sounds`.

The chimes play straight from the hooks, so they work even when the menu bar app isn't running. Nothing leaves your Mac.

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel
- Claude Code, in the Claude desktop app's Code tab or the CLI
- To build from source: Xcode Command Line Tools, for `swiftc` and `python3` (`xcode-select --install`)

## Install

### Download

1. Download `ClaudeChimes-<version>.zip` from the [latest release](https://github.com/naumaanh/claude-chimes/releases/latest), unzip it, and move Claude Chimes.app to Applications.
2. Open it. The app isn't notarized by Apple, so macOS will say it can't verify the developer. Open System Settings → Privacy & Security, scroll down, and click Open Anyway. You only do this once. Alternatively, run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Claude Chimes.app"
   ```

3. Click Set Up in the welcome window.

<p>
  <img src="docs/welcome.png" alt="The welcome window, listing what setup will change" width="440">
</p>

### From source

```bash
git clone https://github.com/naumaanh/claude-chimes.git
cd claude-chimes
./install.sh
```

The installer builds Claude Chimes.app into `~/Applications` as one binary for both Apple silicon and Intel, with the chimes and icon bundled inside. It then runs the app's own setup, which:

1. Copies the chimes to `~/.claude/chimes/sounds`.
2. Links the hook entry point, `~/.claude/chimes/chime-hook`, to the app.
3. Adds the hooks listed under [How it works](#how-it-works) to `~/.claude/settings.json`, after saving a backup (`settings.json.bak-chimes-<timestamp>`). Only those hooks change. The rest of the file, including its key order and formatting, stays as it was.

You can run it again safely: it replaces only its own hooks and keeps your settings. Restart any open Claude Code sessions so they load the new hooks. Add `--native` to build only for your Mac's chip, which is about twice as fast.

If you open the app without running the installer, for example a copy built with `app/build.sh`, it shows a welcome window that does the same setup when you click Set Up.

## Using it

The menu bar menu has two lists. Needs Your Input shows sessions with a permission prompt or question waiting, what they're asking, and how long ago. Ready for Your Reply shows sessions that finished a reply in the last day, and Clear Finished empties it. Clicking a desktop chat opens it through the app's `claude://code/continue?session=…` link. Below the lists are a volume slider (it plays a preview when you let go), Mute (⌘M), Settings… (⌘,) and Quit.

A session leaves the list when you reply, approve the tool it asked about, or close it. If Claude quits without closing the session cleanly, after a crash or a closed terminal, the app sees that the process is gone and drops the session as well.

<p>
  <img src="docs/settings.png" alt="The Settings window" width="420">
</p>

The Settings window has five sections:

- Sounds: the Needs input and Finished sounds, each with a play button.
- Volume: the slider and Mute.
- Menu Bar: what the badge counts (Needs input and finished, Needs input only, or Off) and whether finished sessions are listed.
- General: Launch at Login, a button that opens the sounds folder, and Uninstall.
- Health: whether the hooks are installed, the hook link points at this app, your sounds exist, and hook events are arriving. Repair fixes the setup, Copy Diagnostics copies a report for bug reports, and Show Log opens the event log. When a check fails, the menu shows a Setup needs attention item.

### Without the menu bar app

The chimes don't need the app running. Everything lives in `~/.claude/chimes/config`, a plain text file you can edit by hand:

```ini
input=/Users/you/.claude/chimes/sounds/input-nudge.wav
done=/Users/you/.claude/chimes/sounds/done-spark.wav
volume=0.40
muted=0
badge=all
showFinished=1
```

## How it works

Claude Code runs [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on lifecycle events. The installer adds these to `~/.claude/settings.json`, each calling `~/.claude/chimes/chime-hook <event>`:

| Hook | Argument | What it does |
| --- | --- | --- |
| `Notification` | `notification` | Plays the Needs input chime and marks the session as needing you. Idle reminders are skipped. |
| `Stop` | `stop` | Plays the Finished chime and marks the session as ready for your reply. |
| `UserPromptSubmit` | `prompt` | You replied, so the session is cleared. Runs in the background. |
| `PostToolUse` | `tool` | A tool ran, so a pending permission prompt was answered. Runs in the background. |
| `SessionEnd` | `end` | The session closed, so it's cleared. Runs in the background. |

`chime-hook` is the menu bar app's own binary running in hook mode. It plays sounds with `afplay` in the background, so Claude is never kept waiting, and a call takes about 15 ms.

Each waiting session is a small JSON file in `~/.claude/chimes/sessions`. It holds the session ID, the title from the session's local transcript, its folder, the prompt message, its Claude process ID, and for desktop chats the desktop app's chat ID. A file is deleted after a day, or as soon as its process exits. Finished desktop sessions are the exception: the desktop app can restart their process when you reply, so they stay for the full day. Entries without a process ID also stay for the day. Hook events are logged to `~/.claude/chimes/events.log`, which is capped at 256 KB.

## Troubleshooting

Start with Settings → Health. From a terminal you can also run:

```bash
~/.claude/chimes/chime-hook --doctor         # health report and recent events (exit code 1 if something fails)
~/.claude/chimes/chime-hook --repair         # copy missing chimes, relink the hook, re-add the hooks (backs up settings.json)
~/.claude/chimes/chime-hook --list-sessions  # what's waiting on you right now
```

If a session that was already open stays silent, restart it so it loads the hooks. If you moved the app, it relinks itself the next time it launches. If another tool rewrote `settings.json`, use Repair, which adds back only the Claude Chimes hooks.

To avoid hearing two sounds at once, turn off the desktop app's own notification sound: in the Claude desktop app, set Settings → Claude Code → Notification sound to None, or turn off "Play sound for notifications" under System Settings → Notifications → Claude. Banners still show. Leave your Mac's main volume alone, since the chimes play through it.

## Development

`tests/run.sh` builds the app into a throwaway home folder and checks setup, every hook event, session pruning, the health check, log rotation and uninstall. It never touches your real `~/.claude` or the copy of the app you're running. CI runs it on every pull request.

To publish a release, bump `CFBundleShortVersionString` in `app/Info.plist`, add a section to [`CHANGELOG.md`](CHANGELOG.md), and push a matching tag such as `v1.4.0`. The release workflow tests, builds the universal app, and attaches the zip.

## Customizing

To change the sounds, edit the notes, instruments and timing in [`sounds/generate.py`](sounds/generate.py), then run `python3 sounds/generate.py ~/.claude/chimes/sounds`.

To change the menu bar icon, replace [`assets/menubar.svg`](assets/menubar.svg) and `menubar-muted.svg` (18×18, black on transparent), then run `app/build.sh`.

The app's code is in [`app/Sources`](app/Sources): `main.swift` has the menu, the Settings window and hook mode, `Installer.swift` handles setup and removal, `OrderedJSON.swift` edits `settings.json` without reordering it, `Welcome.swift` has the first-run window and Uninstall, and `AppIcon.swift` draws the icon (`--render-app-icon`). Rebuild with `app/build.sh`. The hook link points into the app, so hooks pick up the new build automatically. [`DESIGN.md`](DESIGN.md) describes the visual and interaction rules the app follows.

## Uninstall

Open Settings → General → Uninstall…, or from the repo:

```bash
./uninstall.sh                # removes the hooks, the app, and ~/.claude/chimes
./uninstall.sh --keep-sounds  # same, but keeps ~/.claude/chimes
```

Either way, only Claude Chimes' hooks leave `settings.json`, after a backup.

## License

[MIT](LICENSE)
