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

  # The app isn't notarized. Installing it this way is the person choosing it, so skip the
  # "can't verify the developer" stop that a download would hit.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Claude Chimes.app"]
  end

  # Removing the app leaves its hooks in ~/.claude/settings.json pointing at nothing, so
  # take them out first, the same way Settings → Uninstall does.
  uninstall_preflight do
    system_command "#{appdir}/Claude Chimes.app/Contents/MacOS/ClaudeChimes", args: ["--uninstall"]
  end

  zap trash: "~/.claude/chimes"
end
