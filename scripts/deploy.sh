#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Deploy Minfolio to the Kindle: parse-check and scp. Restart KOReader manually.
# Usage: scripts/deploy.sh [ssh-host]
set -e
HOST="${1:-kindle}"
DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN="$DIR/minfolio.koplugin/main.lua"
SYNC="$DIR/minfolio.koplugin/minfolio_sync.lua"
SYNC_LAUNCHER="$DIR/minfolio.koplugin/minfolio_sync.sh"
REMOTE="/mnt/us/koreader/plugins/minfolio.koplugin/main.lua"

echo "Deploying to $HOST ..."
ssh "$HOST" "mkdir -p /mnt/us/koreader/plugins/minfolio.koplugin"
scp -O "$DIR/minfolio.koplugin/_meta.lua" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/_meta.lua"
scp -O "$PLUGIN" "$HOST:$REMOTE"
scp -O "$SYNC" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/minfolio_sync.lua"
scp -O "$SYNC_LAUNCHER" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/minfolio_sync.sh"
ssh "$HOST" 'chmod 755 /mnt/us/koreader/plugins/minfolio.koplugin/minfolio_sync.sh'
if [ -f "$DIR/minfolio.koplugin/config.lua" ]; then
    scp -O "$DIR/minfolio.koplugin/config.lua" "$HOST:/mnt/us/koreader/plugins/minfolio.koplugin/config.lua"
fi

echo "Parse-checking on device ..."
ssh "$HOST" 'KO=/mnt/us/koreader; LD_LIBRARY_PATH=$KO/libs:$KO $KO/luajit -e '"'"'local f,e=loadfile("/mnt/us/koreader/plugins/minfolio.koplugin/main.lua"); if not f then io.stderr:write(e .. "\n"); os.exit(1) end; print("PARSE OK")'"'"''
ssh "$HOST" 'KO=/mnt/us/koreader; LD_LIBRARY_PATH=$KO/libs:$KO $KO/luajit -e '"'"'local f,e=loadfile("/mnt/us/koreader/plugins/minfolio.koplugin/minfolio_sync.lua"); if not f then io.stderr:write(e .. "\n"); os.exit(1) end; print("SYNC PARSE OK")'"'"''
echo "Deployed. Restart KOReader manually when you are ready."
