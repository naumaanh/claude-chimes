# Design System: Claude Chimes

The rules the menu bar app follows, and the reference for anything new: screens, mockups, or a project page generated with Google Stitch.

## 1. Visual theme and atmosphere

Quiet, native and ambient. Claude Chimes sits in the menu bar all day, so it should feel like part of macOS rather than an app asking for attention. The menu bar icon is a single thin sine wave. Color appears only when something is actually waiting on you, as a small badge beside the wave.

- Density: 5 of 10, daily-app balanced. The menu is a short list, and Settings is a grouped form with generous rows.
- Variance: 3 of 10, predictable. Native menus and grouped forms are symmetric on purpose, because familiar layouts are faster to use.
- Motion: 2 of 10, static and restrained. Nothing animates on its own (see section 6).

## 2. Color palette and roles

The app uses macOS dynamic system colors, so it follows light mode, dark mode and the user's accent color. The hex values are the light/dark appearance, for mockups.

- Menu Ink (template, tinted by macOS; #1D1D1F light, #F5F5F7 dark): the menu bar wave icon. The SVG is drawn in pure black only because template images require it. macOS replaces the color.
- Waiting Red (systemRed: #FF3B30 light, #FF453A dark): the badge when at least one session needs your input. It's the only alerting color and appears only in that state.
- Idle Gray (systemGray: #8E8E93 light, #98989D dark): the badge when sessions are only ready for your reply. Something is there, but nothing is urgent.
- Badge Numeral (#FFFFFF): the count inside either badge.
- Secondary Text (secondaryLabelColor: about #6E6E73 light, #98989D dark): captions, helper text and session subtitles.
- Health Green, Orange and Red (systemGreen, systemOrange, systemRed): status icons in Settings → Health only. They never appear in the menu bar.
- Accent: the user's macOS accent color, through standard controls (toggles, slider, links). The app sets no brand accent of its own.

## 3. Typography rules

- Native app: SF Pro, the system font, at system sizes (`.menuFont`, `.body`, `.caption`). Numbers in the volume readout use monospaced digits so the percentage doesn't jitter while dragging. The badge numeral is SF Pro Bold at 9 pt.
- Web mockups and a project page (Stitch): Geist for text and Geist Mono for paths, commands and numbers, since SF Pro can't be used on the web. Not Inter. No serif fonts anywhere, since this is software UI.
- Copy: sentence case in Settings, title case for menu section headers (the macOS convention). Use plain verbs: "Repair", "Show Log", "Clear Finished".

## 4. Component stylings

- Menu bar icon: an 18×18 pt template image. When there's a count, a pill badge 12 pt tall sits 2 pt to the right of the wave, never on top of it. An earlier overlapping badge cut into the wave and was dropped. Above nine, show "9+".
- Menu: a native NSMenu, rebuilt each time it opens. Only sections with content are shown. When nothing is waiting, it shows a single disabled line, "Nothing waiting on you". Session rows are the title on the first line, then a subtitle with the prompt message and a relative time ("just now", "4 min ago"). The icon is red for needs-input sessions and gray for finished ones. A faint × at the end of each row dismisses that session without closing the menu. The row draws the native rounded selection on hover and switches to the selected-menu text colors, and VoiceOver gets Open as the press action and Dismiss as a custom action.
- Volume slider (in the menu and in Settings): previews the Finished sound once, when you let go, never while dragging.
- Settings window: a SwiftUI grouped Form, 500 pt wide, with its position remembered between launches. Each sound row is the label with a caption, then a 150 pt picker, then a borderless play button. Choosing a sound plays it once. Reloading settings from disk never plays anything.
- Health rows: a status icon, then the title with a one-line caption saying what's wrong and what to do. Repair is enabled only when a check fails or the link points at another copy. Status messages under the buttons clear after 4 to 8 seconds.
- App icon: the same sine wave in off-white (#F5F5F7) on a charcoal rounded square (#1B1B1E), following the macOS icon grid: an 824-of-1024 tile, a 185 px corner radius, a soft drop shadow, and a faint top light. It's drawn in code (`AppIcon.swift`), so it stays in step with the menu bar icon.
- Banner: a 340×66 pt card with a frosted popover material, a 14 pt corner radius, a hairline separator border and a system shadow. It shows a caption ("Needs your input" in red, or "Ready for your reply" in gray), the session title in 13 pt semibold, and one detail line, with a faint × on the right. It floats at menu bar level on every Space without taking focus, 12 pt from the screen edge, and up to three stack 8 pt apart, newest nearest the edge.
- Welcome window: 440 pt wide. It shows the icon and name, one paragraph on what the app does, and an exact list of what setup will change, then Not Now and Set Up (the default button). After setup it shows the two things to do next. It never sets anything up without a click.
- Uninstall: a confirmation alert with a destructive Uninstall button, a checkbox to also delete sounds and settings (off by default), and the app moved to the Trash rather than deleted.
- Empty, error and loading states: the menu's empty line and Health's warnings are the empty and error states. Nothing takes long enough to need a loader.

## 5. Layout principles

- Native containers only: NSMenu, NSStatusItem, a SwiftUI Form in an NSWindow. Don't build custom menu bar popovers.
- Menu order: setup warning (only when unhealthy), Needs Your Input, Ready for Your Reply, volume, Mute, Settings…, Quit.
- Settings order: Sounds, Volume, Menu Bar, General, Health, About. The most-changed settings go at the top.
- For a project page: content no wider than 1100 px, a single column under 768 px, no horizontal scrolling, and touch targets of at least 44 px.

## 6. Motion and interaction

- No animation in the menu bar icon, the badge, or the menu. Users see them dozens of times a day, and at that frequency motion makes the interface feel slow and distracting.
- Banners are the one exception: they're occasional, so they enter with opacity plus an 8 pt slide (ease-out `cubic-bezier(0.23, 1, 0.32, 1)`, 200 ms) and leave faster (fade, 150 ms). Stacked banners reflow with ease-in-out. With Reduce Motion on they only fade. The timer pauses while the pointer is over a banner.
- Sound is the app's motion. The chimes are the only time-based feedback, and each one plays once, never on a loop.
- Feedback should be immediate. A picker change plays its sound at once, the badge updates the moment a hook writes its file, and a press gives the standard control response.
- A project page may use restrained entrance motion (opacity plus about 8 px of translate, ease-out, under 300 ms, staggered 50 ms between items), and must honor `prefers-reduced-motion`. No perpetual loops, no scroll hijacking.

## 7. Anti-patterns (banned)

- Emojis anywhere, in the UI, copy or icons.
- An icon or badge that animates, pulses or bounces. A banner that bounces, loops, or takes focus from the app you're in.
- A second alerting color, or red for anything except "a session needs your input".
- A badge that overlaps the wave.
- Inter, or any serif font.
- Neon glows, gradient text, glassmorphism, custom cursors.
- A sound preview that fires without a user action, or that loops.
- Copy clichés: "seamless", "elevate", "supercharge", "unleash".
- Meta labels like "SECTION 01", and filler such as "Scroll to explore".
- Claiming to be official, or using Anthropic's logo or brand marks. The project is unofficial and says so.
