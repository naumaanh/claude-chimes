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

- **Menu bar app** for choosing each sound (including the built-in macOS sounds), a volume slider, mute, test buttons, and Launch at Login.
- **Bring your own sounds**: drop any `.wav`, `.aiff`, `.mp3`, `.m4a` or `.caf` into `~/.claude/chimes/sounds` and it appears in the menu.
- **Light touch**: two Claude Code hooks and one small shell script, with no background process needed to play sounds. The menu bar app is just for changing settings.

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
2. Copies the hook script to `~/.claude/chimes/chime.sh`.
3. Adds a `Notification` hook and a `Stop` hook to `~/.claude/settings.json`. It keeps your other settings and hooks, and saves a backup first (`settings.json.bak-chimes-<timestamp>`).
4. Builds **Claude Chimes.app** into `~/Applications` and opens it.

Running it again is safe. It replaces its own hooks and keeps your sound choices. Restart any open Claude Code sessions so they pick up the new hooks.

## Using it

Click the icon in the menu bar:

- **Needs Input / Finished**: pick a sound. Choosing one plays a preview.
- **Volume**: drag the slider. It previews on release. The default is 40%.
- **Mute** (⌘M): silences both sounds and keeps your choices.
- **Play Needs Input / Play Finished**: hear the current sounds.
- **Open Sounds Folder**: add your own audio files.
- **Launch at Login**: keep the menu bar app around after a restart. The sounds work without it.

### Without the menu bar app

Everything lives in `~/.claude/chimes/config`, a plain text file you can edit by hand:

```ini
input=/Users/you/.claude/chimes/sounds/input-nudge.wav
done=/Users/you/.claude/chimes/sounds/done-spark.wav
volume=0.40
muted=0
```

## How it works

Claude Code runs [hooks](https://docs.claude.com/en/docs/claude-code/hooks) on lifecycle events. The installer adds these to `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Notification": [{ "hooks": [{ "type": "command", "command": "~/.claude/chimes/chime.sh input", "timeout": 5 }] }],
    "Stop":         [{ "hooks": [{ "type": "command", "command": "~/.claude/chimes/chime.sh done",  "timeout": 5 }] }]
  }
}
```

`chime.sh` reads the config and plays the chosen file with `afplay` in the background, so Claude is never kept waiting.

**Tip:** to avoid hearing two sounds, turn off the desktop app's own notification sound. In the Claude desktop app, open Settings → Claude Code and set Notification sound to None, or open System Settings → Notifications → Claude and turn off "Play sound for notifications". Banners still show. Leave your Mac's main volume alone, since the chimes play through it.

## Customizing

- **Sounds:** edit the notes, instruments, and timing in [`sounds/generate.py`](sounds/generate.py), then run `python3 sounds/generate.py ~/.claude/chimes/sounds`.
- **Menu bar icon:** replace [`assets/menubar.svg`](assets/menubar.svg) and `menubar-muted.svg` (18×18, black on transparent), then run `app/build.sh`.
- **App code:** everything is in [`app/ClaudeChimes.swift`](app/ClaudeChimes.swift). Rebuild with `app/build.sh`.

## Uninstall

```bash
./uninstall.sh                # removes the hooks, the app, and ~/.claude/chimes
./uninstall.sh --keep-sounds  # same, but keeps ~/.claude/chimes
```

## License

[MIT](LICENSE)
