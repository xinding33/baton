#!/bin/bash
# Runs on the Mac being set up: writes a default config if there is none, then (re)starts the agent.
# Usage: install-agent.sh <name> <anchor|client>
set -euo pipefail

NAME=$1
ROLE=$2
LABEL=com.xinding.baton
SUPPORT="$HOME/Library/Application Support/Baton"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/Baton"
chmod 700 "$SUPPORT"
chmod 600 "$SUPPORT/secret.key"

if [ ! -f "$SUPPORT/config.json" ]; then
    if [ "$ROLE" = anchor ]; then
        cat > "$SUPPORT/config.json" <<JSON
{
  "name": "$NAME",
  "role": "anchor",
  "placements": [
    { "machine": "mini", "side": "left", "of": "$NAME", "align": "end" },
    { "machine": "mbp", "side": "right", "of": "$NAME", "align": "end" }
  ],
  "timeoutMs": { "mbp": 1500 }
}
JSON
    else
        printf '{\n  "name": "%s",\n  "role": "client"\n}\n' "$NAME" > "$SUPPORT/config.json"
    fi
fi

cat > "$PLIST" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Applications/Baton.app/Contents/MacOS/Baton</string>
    </array>
    <key>AssociatedBundleIdentifiers</key>
    <string>$LABEL</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
XML

# Stopping is asynchronous; starting again before it finishes fails.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 50); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "$NAME: agent started"
