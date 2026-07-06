#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Deploy Minfolio to the Kindle: parse-check, scp, restart KOReader.
# Usage: scripts/deploy.sh [ssh-host]   (default host: kindle)
set -e
HOST="${1:-kindle}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$DIR/minfolio.koplugin/main.lua"
REMOTE="/mnt/us/koreader/plugins/minfolio.koplugin/main.lua"

echo "Deploying to $HOST ..."
ssh "$HOST" "mkdir -p /mnt/us/koreader/plugins/minfolio.koplugin"
scp -O "$DIR/minfolio.koplugin/_meta.lua" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/_meta.lua"
scp -O "$PLUGIN" "$HOST:$REMOTE"
if [ -f "$DIR/minfolio.koplugin/config.lua" ]; then
    scp -O "$DIR/minfolio.koplugin/config.lua" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/config.lua"
fi

echo "Parse-checking on device ..."
ssh "$HOST" 'KO=/mnt/us/koreader; LD_LIBRARY_PATH=$KO/libs:$KO $KO/luajit -e '"'"'local f,e=loadfile("/mnt/us/koreader/plugins/minfolio.koplugin/main.lua"); print(f and "PARSE OK" or e)'"'"''

echo "Restarting KOReader (relaunch via KUAL to test) ..."
ssh "$HOST" 'for p in $(pgrep -f "[.]/luajit ./reader.lua"); do kill -TERM "$p"; done; sleep 3; for p in $(pgrep -f "[.]/luajit ./reader.lua"); do kill -9 "$p"; done; sleep 1; status lab126_gui | grep -q running || start lab126_gui; echo restarted'
