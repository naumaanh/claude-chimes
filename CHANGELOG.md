# Changelog

## [1.6.0] - 2026-11-05

### Added
- Only longer turns chime. Finished plays, and its banner shows, only when Claude worked longer than a threshold (default 30 seconds). Quick back-and-forth stays quiet. Settings → When to Chime → "Chime when Claude finishes".
- A reminder chime and banner, once, for a permission prompt or question left unanswered (default 5 minutes). This needs the menu bar app to be running.
- An error chime ("Dip") and a "Turn failed" banner and menu row when a turn ends with an error, through Claude Code's `StopFailure` hook.
- An optional soft cue before Claude compacts the conversation (`PreCompact` hook), off by default.
- Quiet hours: a daily window, which can wrap past midnight, that mutes chimes, banners and reminders while sessions are still tracked.

### Changed
- Sending a message now marks a session as working instead of clearing it, and a tool run after a permission prompt returns it to working. That's what makes turn length measurable, and it sets up a Working section.
- Existing installs get the two new hooks automatically the next time the app launches. Only Claude Chimes' hooks change.

## [1.5.0] - 2026-11-05

### Added
- On-screen banners. When a session needs your input or finishes, a small card names the session and what it's waiting for. Click it to open the session, or × to dismiss it. A banner waits while your pointer is over it, and closes by itself once you reply. Up to three stack at once.
- Settings → Banners: which sessions show a banner (needs input and finished, needs input only, or off), where it appears (top right, top center or bottom right), how long it stays (4, 8 or 15 seconds, or until dismissed), and Show Test Banner.

## [1.4.1] - 2026-11-05

### Fixed
- Two session rows could stay highlighted at once in the menu. The menu's own highlight now drives the rows, so exactly one is highlighted, and it clears when you move to another item or close the menu.

## [1.4.0] - 2026-11-05

### Added
- An × on every session in the menu dismisses just that session when you're done with it, and the menu stays open. `--dismiss <id>` does the same from a terminal.
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
