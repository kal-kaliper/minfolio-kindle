# Minfolio for Kindle

A native KOReader **live-styled Markdown editor** for a jailbroken Kindle Paperwhite 5. It renders
header/bold/italic/code/list styling as you type, renders pipe tables in reader mode with direct cell
editing, and provides an overlay caret, word wrap, undo/redo, selection + copy/paste, on-screen and
Bluetooth keyboards, a rendered reader mode, and A−/A+ zoom.
Notes are saved as `.md` to `/mnt/us/notes`.

Minfolio is the standalone notes editor plugin and KUAL launcher.

## Layout

| Path | Role |
|---|---|
| `minfolio.koplugin/main.lua` | The plugin: `MDEdit` editor, Markdown renderer, notes browser, plugin entry. |
| `minfolio.koplugin/_meta.lua` | Plugin metadata. |
| `minfolio.koplugin/config.example.lua` | Optional local config template. Copy to `config.lua` on the device to override defaults. |
| `minfolio-kual/` | KUAL extension: `config.xml`, `menu.json`, `bin/notes.sh`. |
| `scripts/deploy.sh` | Parse-check + `scp` to the device + restart KOReader. |

## Install

Install the KOReader plugin:

```sh
mkdir -p /mnt/us/koreader/plugins/minfolio.koplugin
cp minfolio.koplugin/main.lua /mnt/us/koreader/plugins/minfolio.koplugin/
cp minfolio.koplugin/_meta.lua /mnt/us/koreader/plugins/minfolio.koplugin/
```

Install the KUAL launcher as `/mnt/us/extensions/minfolio`:

```sh
mkdir -p /mnt/us/extensions/minfolio
cp -R minfolio-kual/* /mnt/us/extensions/minfolio/
```

The launcher writes `notes` to `/tmp/minfolio_launch` and starts KOReader through
`/mnt/us/koreader/koreader.sh --kual`.

## Config

Minfolio works without a config file. Defaults:

```lua
notes_dir = "/mnt/us/notes"
state_dir = "/mnt/us/minfolio"
minfolio_scale = 1.0
```

To override them, copy `minfolio.koplugin/config.example.lua` to
`/mnt/us/koreader/plugins/minfolio.koplugin/config.lua` and edit it on the device. The real
`config.lua` is gitignored so local paths and device-specific settings are not committed.

## Development Deploy

The device is reached over SSH (`ssh kindle`, or `kindle.local`). Deploy = parse-check with the
device's own LuaJIT, `scp` `main.lua` to `/mnt/us/koreader/plugins/minfolio.koplugin/`, then restart
KOReader. See `scripts/deploy.sh`.

A Lua syntax error makes KOReader silently skip the whole plugin — always parse-check before trusting
a deploy.

## Validation

```sh
luajit -e 'local f,e=loadfile("minfolio.koplugin/main.lua"); if not f then print(e); os.exit(1) else print("PARSE OK") end'
jq empty minfolio-kual/menu.json
sh -n scripts/deploy.sh minfolio-kual/bin/notes.sh
```

## License

Minfolio is licensed under AGPL-3.0-only, matching KOReader's strong copyleft license family.
