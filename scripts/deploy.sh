#!/bin/bash
# Builds Baton.app, signs it, and installs it on this Mac (the anchor) and the client Macs.
# Usage: deploy.sh [name ...]   (default: all machines)
set -euo pipefail
cd "$(dirname "$0")/.."

# Layout name, role, and SSH host of each machine. "local" is the Mac running this script.
MACHINES=(
    "studio anchor local"
    "mini client mac-mini"
    "mbp client macbook"
)
IDENTITY="${BATON_IDENTITY:-Developer ID Application}"
APP=build/Baton.app
SUPPORT="Library/Application Support/Baton"

swift build -c release 2>&1 | tail -1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Baton" "$APP/Contents/MacOS/Baton"
cp scripts/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "$IDENTITY" "$APP"

# Every machine shares one secret; it is created here once and copied to the others.
mkdir -p "$HOME/$SUPPORT"
if [ ! -f "$HOME/$SUPPORT/secret.key" ]; then
    (umask 077 && openssl rand -hex 32 > "$HOME/$SUPPORT/secret.key")
fi

for machine in "${MACHINES[@]}"; do
    read -r name role host <<< "$machine"
    if [ $# -gt 0 ] && [[ ! " $* " == *" $name "* ]]; then continue; fi
    if [ "$host" = local ]; then
        mkdir -p "$HOME/Applications"
        rsync -a --delete "$APP/" "$HOME/Applications/Baton.app/"
        bash scripts/install-agent.sh "$name" "$role"
    else
        ssh "$host" "mkdir -p Applications '$SUPPORT' && chmod 700 '$SUPPORT'"
        rsync -a --delete "$APP/" "$host:Applications/Baton.app/"
        ssh "$host" "umask 077 && cat > '$SUPPORT/secret.key'" < "$HOME/$SUPPORT/secret.key"
        ssh "$host" bash -s "$name" "$role" < scripts/install-agent.sh
    fi
done
