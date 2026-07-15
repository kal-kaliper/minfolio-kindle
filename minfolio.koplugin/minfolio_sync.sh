#!/bin/sh
# SPDX-License-Identifier: AGPL-3.0-only
# Keep KOReader's Lua search paths out of the desktop SSH command.  Shell
# quoting across SSH is fragile; this tiny local launcher makes worker startup
# deterministic and keeps network work outside the KOReader UI process.
set -eu
KO=/mnt/us/koreader
export LD_LIBRARY_PATH="$KO/libs:$KO"
export LUA_PATH="$KO/common/?.lua;$KO/common/?/init.lua;;"
export LUA_CPATH="$KO/common/?.so;$KO/common/?/?.so;;"
exec "$KO/luajit" "$KO/plugins/minfolio.koplugin/minfolio_sync.lua" "$1"
