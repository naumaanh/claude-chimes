# Changelog

## [1.4.0] - 2026-11-05

### Added
- The app is self-contained. The six chimes and the icon are bundled, and the app sets itself up, so a downloaded copy works without the repo or Xcode tools.
- First-run welcome window. It appears when the hooks are missing, lists exactly what setup will change, and does the setup on Set Up.
- Uninstall from Settings → General. It removes the hooks after a backup, can also delete your sounds and settings, and moves the app to the Trash.
- App icon: the menu bar wave on a charcoal tile.
- One universal binary for Apple silicon and Intel Macs.
- `--setup` and `--uninstall [--delete-data]` command-line flags. `install.sh` and `uninstall.sh` now use them.
- Test suite (`tests/run.sh`), CI on every pull request, and a release workflow that attaches a zip to each version tag.

### Changed
- `settings.json` is edited without reordering it. Only Claude Chimes' hooks change, keys keep their order and numbers keep their spelling, and a setup that changes nothing doesn't rewrite the file.
- The source is split into `app/Sources/*.swift`.

## [1.3.0] - 2026-11-05

### Added
- Clicking a desktop-app chat in the menu opens that chat, through `claude://code/continue?session=…`.
- Settings → Health checks the hooks, the hook link, the sound files and recent events, with Repair, Copy Diagnostics and Show Log. The menu shows "Setup needs attention" when a check fails.
- An event log at `~/.claude/chimes/events.log`, capped at 256 KB.
- `--doctor`, `--repair` and `--list-sessions` command-line flags.
- `DESIGN.md`, describing the app's visual and interaction rules.

### Changed
- Sessions whose Claude process has exited are dropped from the menu. Finished desktop chats are kept, since the app can restart them.
- The app relinks its hook when it's moved.
- Sound pickers preview only when you pick, Repair is enabled only when needed, and the menu hides empty sections.

## [1.2.0] - 2026-11-05

### Added
- A number badge beside the menu bar icon: red when a session needs your input, gray when sessions are only ready for your reply. You choose what it counts in Settings.

## [1.1.0] - 2026-11-05

### Added
- The menu lists sessions that need your input and sessions ready for your reply, with titles from each session's transcript.
- A Settings window for sounds, volume, menu bar options and Launch at Login.
- The app binary doubles as the hook (`~/.claude/chimes/chime-hook`). New `UserPromptSubmit`, `PostToolUse` and `SessionEnd` hooks clear sessions.

### Changed
- Idle reminders no longer play a second chime after a reply.

## [1.0.0] - 2026-11-05

### Added
- Six synthesized chimes, played from Claude Code's `Notification` and `Stop` hooks.
- A menu bar app for choosing sounds and setting the volume.
- `install.sh` and `uninstall.sh`.
