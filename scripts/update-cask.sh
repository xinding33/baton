#!/bin/bash
# Writes the baton cask for a release into a homebrew-tap checkout.
# Usage: scripts/update-cask.sh TAP_DIR VERSION SHA256
#
# The cask says `auto_updates true`, so `brew upgrade` leaves Baton alone: every release
# updates itself, on all the Macs together, and upgrading one Mac from brew would stop Baton
# there and unload its launch agent.
set -euo pipefail
TAP="$1" VERSION="$2" SHA="$3"
mkdir -p "$TAP/Casks"
cat > "$TAP/Casks/baton.rb" <<CASK
cask "baton" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/xinding33/baton/releases/download/v#{version}/Baton-#{version}.zip"
  name "Baton"
  desc "Shares one mouse and keyboard across several Macs"
  homepage "https://github.com/xinding33/baton"

  auto_updates true
  depends_on macos: :sonoma

  app "Baton.app"

  uninstall launchctl: "com.xinding.baton",
            quit:      "com.xinding.baton"

  zap trash: [
    "~/Library/Application Support/Baton",
    "~/Library/LaunchAgents/com.xinding.baton.plist",
    "~/Library/Logs/Baton",
  ]
end
CASK
