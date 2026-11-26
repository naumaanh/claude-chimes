# Homebrew cask for Claude Chimes. This repository doubles as its own tap:
#
#   brew tap naumaanh/claude-chimes https://github.com/naumaanh/claude-chimes
#   brew install --cask claude-chimes
#
# The release workflow checks that `version` here matches app/Info.plist, so bump both.
cask "claude-chimes" do
  version "1.8.0"
  # The zip is built and attached by the release workflow; there is no fixed checksum to pin
  # before the tag is pushed, so this tap does not pin one.
  sha256 :no_check

  url "https://github.com/naumaanh/claude-chimes/releases/download/v#{version}/ClaudeChimes-#{version}.zip"
  name "Claude Chimes"
  desc "Notification sounds and a menu bar list of Claude Code sessions waiting on you"
  homepage "https://github.com/naumaanh/claude-chimes"

  depends_on macos: ">= :sonoma"

  app "Claude Chimes.app"

  # Quarantine is left on: the zip has no pinned checksum, so Gatekeeper's check is the one
  # check left. The first launch asks once (Privacy & Security → Open Anyway), as a download does.

  # No uninstall step that removes the hooks: Homebrew runs uninstall steps on every
  # `brew upgrade` too, and the new version only restores hooks when some are still there,
  # so upgrading would silence it for good. The hooks point at the app's own path, which
  # an upgrade keeps.
  caveats <<~EOS
    Claude Chimes isn't notarized, so the first time it opens macOS asks once: open
    System Settings → Privacy & Security and click Open Anyway.

    To remove Claude Chimes completely, first use Settings → Uninstall in the app (it takes
    its hooks out of ~/.claude/settings.json), then run `brew uninstall --cask claude-chimes`.
  EOS

  zap trash: "~/.claude/chimes"
end
