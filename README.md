# Minfolio Markdown Editor for Kindle

**A simple, distraction-free Markdown editor and word processor for your Kindle.**

Minfolio turns a jailbroken Kindle into a comfortable writing device: weeks of battery, a glare-free
e-ink screen, and nothing on it but your words. You type in plain Markdown and watch it style itself
as you go, with headings, bold, italic, code, and lists rendered live while you write. Your work saves
automatically as ordinary `.md` files you can sync anywhere.

## Why write on a Kindle

- **No distractions.** No browser, no notifications, no feed. Just the page.
- **Easy on the eyes.** E-ink is paper-like and readable in bright sun, with no backlight fatigue.
- **All-day (all-week) battery.** Write for hours; charge rarely.
- **Light and pocketable.** Pair a Bluetooth keyboard and you have a featherweight writing setup.
- **Plain files you own.** Everything is Markdown on disk, not locked in an app.

## Features

- **Live styling as you type** — headings, **bold**, *italic*, `code`, and lists render inline while you write.
- **Tables** — write pipe tables and edit cells directly in a rendered reader view.
- **Reader mode** — flip from editing to a clean, fully rendered view of your document.
- **Real editing** — overlay caret, word wrap, undo/redo, selection, and copy/paste.
- **Type your way** — on-screen keyboard or a paired Bluetooth keyboard.
- **Adjustable text size** — A−/A+ zoom for comfortable writing.
- **Autosaves to Markdown** — notes are stored as `.md` in `/mnt/us/notes`, ready to sync.
- **Built-in notes browser** — open, create, and switch between notes without leaving the app.

## Requirements

Minfolio is built and tested on a **jailbroken Kindle Paperwhite 5**. It runs as a
[KOReader](https://github.com/koreader/koreader) plugin launched from
[KUAL](https://www.mobileread.com/forums/showthread.php?t=225030), so other KOReader-capable Kindles
may work too, though only the Paperwhite 5 is tested.

You will need a jailbroken Kindle with KOReader and KUAL already installed.

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

Then open Minfolio from the KUAL menu. (The launcher writes `notes` to `/tmp/minfolio_launch` and
starts KOReader through `/mnt/us/koreader/koreader.sh --kual`.)

## Config

Minfolio works with no configuration. The defaults are:

```lua
notes_dir      = "/mnt/us/notes"     -- where your .md files live
state_dir      = "/mnt/us/minfolio"  -- where app state is stored
minfolio_scale = 1.0                 -- text zoom level
```

To change them, copy `minfolio.koplugin/config.example.lua` to
`/mnt/us/koreader/plugins/minfolio.koplugin/config.lua` and edit it on the device. Your `config.lua`
is gitignored, so device-specific paths stay local.

## Project layout

| Path | Role |
|---|---|
| `minfolio.koplugin/main.lua` | The plugin: `MDEdit` editor, Markdown renderer, notes browser, plugin entry. |
| `minfolio.koplugin/_meta.lua` | Plugin metadata. |
| `minfolio.koplugin/config.example.lua` | Optional local config template. |
| `minfolio-kual/` | KUAL launcher: `config.xml`, `menu.json`, `bin/notes.sh`. |
| `scripts/deploy.sh` | Developer helper: parse-check, `scp` to the device, restart KOReader. |

## Development

Deploy over SSH (`ssh kindle`, or `kindle.local`): parse-check with the device's own LuaJIT, `scp`
`main.lua` to the plugin directory, then restart KOReader. See `scripts/deploy.sh`.

A Lua syntax error makes KOReader silently skip the whole plugin, so always parse-check before trusting
a deploy:

```sh
luajit -e 'local f,e=loadfile("minfolio.koplugin/main.lua"); if not f then print(e); os.exit(1) else print("PARSE OK") end'
jq empty minfolio-kual/menu.json
sh -n scripts/deploy.sh minfolio-kual/bin/notes.sh
```

## Sister app

**[Minfolio](https://github.com/kal-kaliper/minfolio)** is the desktop and mobile counterpart: a clean,
minimalist WYSIWYG Markdown editor and mind-mapping app for macOS, Android, and Meta Quest, built to
work alongside LLMs. Both apps edit plain `.md` files, so notes you write on the Kindle open right up in
Minfolio on your other devices.

## License

Minfolio is licensed under AGPL-3.0-only, matching KOReader's strong copyleft license family. See
[`LICENSE`](LICENSE).

## Trademark

Kindle is a trademark of Amazon. Minfolio is an independent project and is not affiliated with,
endorsed by, or sponsored by Amazon. "for Kindle" describes compatibility only.
