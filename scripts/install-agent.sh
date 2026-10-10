#!/bin/bash
# Runs on the Mac being set up: writes a default config if there is none, then (re)starts Baton.
# Usage: install-agent.sh <name> <anchor|client>
#
# Open at Login is Baton's launch agent, and the app writes it itself (`Baton login on`). It is
# turned on for a Mac that is set up here for the first time. After that it is left the way that
# Mac has it: where it was switched off in the menu, the new build is started with `open` and no
# agent is written. BATON_LOGIN=on switches it back on.
set -euo pipefail

NAME=$1
ROLE=$2
LABEL=com.xinding.baton
APP="$HOME/Applications/Baton.app"
BATON="$APP/Contents/MacOS/Baton"
SUPPORT="$HOME/Library/Application Support/Baton"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$SUPPORT" "$HOME/Library/Logs/Baton"
chmod 700 "$SUPPORT"
chmod 600 "$SUPPORT/secret.key"

LOGIN=${BATON_LOGIN:-}
if [ -f "$PLIST" ] || [ ! -f "$SUPPORT/config.json" ]; then
    LOGIN=on
fi

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

if [ "$LOGIN" = on ]; then
    "$BATON" login on > /dev/null
fi

# Stopping is asynchronous; starting again before it finishes fails.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
for _ in $(seq 50); do
    launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
done
# A copy that was opened by hand is not launchd's to stop. The pattern is the installed program
# with no arguments, which leaves out `Baton ctl`, the display watchdog and builds run elsewhere.
pkill -TERM -f "^$BATON\$" 2>/dev/null || true
for _ in $(seq 50); do
    pgrep -f "^$BATON\$" >/dev/null 2>&1 || break
    sleep 0.1
done

if [ "$LOGIN" = on ]; then
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "$NAME: agent started"
else
    open "$APP"
    echo "$NAME: started without a launch agent, because Open at Login is off on this Mac (BATON_LOGIN=on switches it on)"
fi
