# Release Checklist

Run these before publishing or tagging a release.

```sh
luajit -e 'local f,e=loadfile("minfolio.koplugin/main.lua"); if not f then print(e); os.exit(1) else print("PARSE OK") end'
jq empty minfolio-kual/menu.json
sh -n scripts/deploy.sh minfolio-kual/bin/notes.sh
rg -n '\b(TOKEN|SERVER_DROP|192\.168|tandemic)\b|/Users/|password|secret|apikey|api_key|bearer' -g '!LICENSE' -g '!RELEASE_CHECKLIST.md' -g '!*node_modules*' .
git status --short --ignored
```

Before release:

- Confirm `minfolio.koplugin/config.lua` is not tracked.
- Confirm Dropbear/screensaver watchdog files are not tracked unless intentionally added as documented utilities.
- Deploy to a Kindle and smoke-test launch, note creation, edit/save, reader mode, and KUAL relaunch.
