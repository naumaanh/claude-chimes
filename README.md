# claude-chimes

Custom notification sounds for Claude, with a minimal macOS menu bar app to pick sounds and set the volume.

Claude Chimes plays a soft chime when Claude **needs your input** (a permission prompt or a question) and another when it **finishes a reply**. It works anywhere Claude Code runs on your Mac:

- the **Code tab** of the Claude desktop app
- the **`claude` CLI** in your terminal

It doesn't apply to regular chats in the desktop app or on claude.ai, which don't run Claude Code hooks.

> Unofficial community project. Not made by, endorsed by, or affiliated with Anthropic.

## Features

- **Six original chimes**, synthesized on your Mac by a small Python script (no audio files are downloaded):

  | Needs input | Finished |
  | --- | --- |
  | **Nudge**: two soft marimba notes, rising | **Spark**: a quick sparkle into a warm chord |
  | **Query**: three glassy bell notes, unresolved | **Settle**: three descending kalimba notes |
  | **Knock**: two muted wooden taps | **Bloom**: a slow, warm chord that rings out |

- **See what's waiting on you.** The menu bar lists Claude sessions that need your input (with what they're asking) and sessions that finished and are ready for your reply. Click a session to jump to the app it's running in.
- **Badge on the icon**: a number beside the menu bar icon counts the sessions waiting on you. It's red when one needs your input and gray when they're only ready for your reply. You can count both, only those needing input, or turn it off.
- **Quick controls in the menu**: volume and mute.
- **Settings window** for picking each sound (bundled chimes, your own files, or macOS sounds), previewing them, menu bar options, and Launch at Login.
- **Bring your own sounds**: drop any `.wav`, `.aiff`, `.mp3`, `.m4a` or `.caf` into `~/.claude/chimes/sounds` and it appears in Settings.
- **Light touch**: chimes play straight from the hooks, so they work even when the menu bar app isn't running. Everything stays on your Mac.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode Command Line Tools, for `swiftc` and `python3` (`xcode-select --install`)
- Claude Code, either in the Claude desktop app's Code tab or the CLI

## Install

```bash
git clone https://github.com/naumaanh/claude-chimes.git
cd claude-chimes
./install.sh
```

The installer:

1. Generates the chimes into `~/.claude/chimes/sounds`.
2. Builds **Claude Chimes.app** into `~/Applications`, and links its hook entry point to `~/.claude/chimes/chime-hook`.
3. Adds hooks to `~/.claude/settings.json` (listed under [How it works](#how-it-works)). It keeps your other settings and hooks, and saves a backup first (`settings.json.bak-chimes-<timestamp>`).
4. Opens the app.

Running it again is safe. It replaces its own hooks and keeps your settings. Restart any open Claude Code sessions so they pick up the new hooks.

## Using it

**The menu bar menu**

- **Needs Your Input**: sessions with a permission prompt or a question waiting, plus what they're asking and how long ago.
- **Ready for Your Reply**: sessions that finished a reply in the last day. **Clear Finished** empties this list.
- Click a session to bring its app to the front (the Claude desktop app, or your terminal for CLI sessions).
- **Volume** slider (previews on release) and **Mute** (⌘M).
- **Settings…** (⌘,) and **Quit**.

A session leaves the list when you reply to it, approve the tool it was asking about, or close it. If Claude quits without saying so (a crash, or a closed terminal), the app notices the process is gone and drops the session too.

**The Settings window**

- **Sounds**: pick the *Needs input* and *Finished* sounds, with a play button for each.
- **Volume**: slider and Mute.
- **Menu Bar**: what the badge counts (*Needs input and finished*, *Needs input only*, or *Off*), and whether to list finished sessions.
- **General**: Launch at Login, and a button that opens the sounds folder.
- **Health**: checks that the hooks are installed, the hook link points at this app, your sounds exist, and hook events are arriving. **Repair** fixes the setup, **Copy Diagnostics** copies a report for bug reports, and **Show Log** opens the event log. If something breaks, the menu shows a *Setup needs attention* item.

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
| `Notification` | `notification` | Plays the *Needs input* chime and marks the session as needing you. Idle reminders are skipped. |
| `Stop` | `stop` | Plays the *Finished* chime and marks the session as ready for your reply. |
| `UserPromptSubmit` | `prompt` | You replied, so the session is cleared (runs in the background). |
| `PostToolUse` | `tool` | A tool ran, so a pending permission prompt was answered (runs in the background). |
| `SessionEnd` | `end` | The session closed, so it's cleared (runs in the background). |

`chime-hook` is the menu bar app's own binary running in hook mode. It plays sounds with `afplay` in the background, so Claude is never kept waiting. A hook call takes about 15 ms.

Waiting sessions are stored as small JSON files in `~/.claude/chimes/sessions`. Each one holds the session ID, its title (read from the session's local transcript), its folder, the prompt message, and the session's Claude process ID. Entries are deleted after a day, or sooner once their process exits. Two exceptions apply: a finished desktop-app session is kept, since the app can restart its process when you reply, and so is an entry with no process ID. Hook events are logged to `~/.claude/chimes/events.log`, which is capped at 256 KB. Nothing is sent anywhere.

## Troubleshooting

Open **Settings → Health** first. From a terminal you can also run:

```bash
~/.claude/chimes/chime-hook --doctor         # health report and recent events (exit code 1 if something fails)
~/.claude/chimes/chime-hook --repair         # relink the hook and re-add the hooks (backs up settings.json)
~/.claude/chimes/chime-hook --list-sessions  # what's waiting on you right now
```

Common causes:

- **No chimes in a session that was already open:** restart that session so it loads the hooks.
- **You moved the app:** it relinks itself the next time it launches.
- **Another tool rewrote `settings.json`:** use **Repair**.

Repair adds back only its own hooks and keeps everything else. It does write the file with its keys sorted alphabetically.

**Tip:** to avoid hearing two sounds, turn off the desktop app's own notification sound. In the Claude desktop app, open Settings → Claude Code and set Notification sound to None, or open System Settings → Notifications → Claude and turn off "Play sound for notifications". Banners still show. Leave your Mac's main volume alone, since the chimes play through it.

## Customizing

- **Sounds:** edit the notes, instruments, and timing in [`sounds/generate.py`](sounds/generate.py), then run `python3 sounds/generate.py ~/.claude/chimes/sounds`.
- **Menu bar icon:** replace [`assets/menubar.svg`](assets/menubar.svg) and `menubar-muted.svg` (18×18, black on transparent), then run `app/build.sh`.
- **App code:** the menu, the Settings window and hook mode are all in [`app/ClaudeChimes.swift`](app/ClaudeChimes.swift). Rebuild with `app/build.sh`. The hook link points into the app, so it picks up the new build automatically.

## Uninstall

```bash
./uninstall.sh                # removes the hooks, the app, and ~/.claude/chimes
./uninstall.sh --keep-sounds  # same, but keeps ~/.claude/chimes
```

## License

[MIT](LICENSE)
