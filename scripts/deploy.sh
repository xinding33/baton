#!/bin/bash
# Builds Baton.app, signs it, and installs it on this Mac (the anchor) and the client Macs.
# Usage: deploy.sh [name ...]   (default: all machines)
#
# What it builds is a development build: it never replaces itself with a release, so the Macs
# run exactly what was deployed. BATON_APP=<path to a Baton.app> installs that bundle instead,
# e.g. an unzipped release, which from then on keeps every Mac up to date by itself.
set -euo pipefail
cd "$(dirname "$0")/.."

# Layout name, role, and SSH host of each machine. "local" is the Mac running this script.
MACHINES=(
    "studio anchor local"
    "mini client mac-mini"
    "mbp client macbook"
)
IDENTITY="${BATON_IDENTITY:-Developer ID Application}"
APP="${BATON_APP:-dist/Baton.app}"
SUPPORT="Library/Application Support/Baton"

if [ -n "${BATON_APP:-}" ]; then
    codesign --verify --strict "$APP"
else
    # For this Mac's architecture only, but put together and signed as a release is, hardened
    # runtime included, so that what is used every day is what a release will do.
    SIGN_IDENTITY="$IDENTITY" BATON_ARCHS=native BATON_BUILD=development bash scripts/build.sh
fi

# Every machine shares one secret; it is created here once and copied to the others.
mkdir -p "$HOME/$SUPPORT"
if [ ! -f "$HOME/$SUPPORT/secret.key" ]; then
    (umask 077 && openssl rand -hex 32 > "$HOME/$SUPPORT/secret.key")
fi

# Restarting the anchor in the middle of a keyboard handoff leaves the keyboard paired with no Mac.
CTL="$HOME/Applications/Baton.app/Contents/MacOS/Baton"
for _ in $(seq 60); do
    [ -x "$CTL" ] || break
    perl -e 'alarm 6; exec @ARGV' "$CTL" ctl keyboard 2>/dev/null | grep -q '"handoffInProgress" : "[^n]' || break
    echo "waiting for a keyboard handoff to finish"
    sleep 1
done

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
