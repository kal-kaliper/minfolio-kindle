# Release Checklist

Run these before publishing or tagging a release.

```sh
luajit -e 'for _,p in ipairs({"minfolio.koplugin/main.lua", "minfolio.koplugin/minfolio_sync.lua"}) do local f,e=loadfile(p); if not f then print(e); os.exit(1) end end; print("PARSE OK")'
jq empty minfolio-kual/menu.json
sh -n scripts/deploy.sh minfolio-kual/bin/notes.sh minfolio.koplugin/minfolio_sync.sh
rg -n '\b(TOKEN|SERVER_DROP|192\.168|tandemic)\b|/Users/|password|secret|apikey|api_key|bearer' -g '!LICENSE' -g '!RELEASE_CHECKLIST.md' -g '!*node_modules*' .
git status --short --ignored
```

Before release:

- Confirm `minfolio.koplugin/config.lua` is not tracked.
- Confirm Dropbear/screensaver watchdog files are not tracked unless intentionally added as documented utilities.
- Deploy to a Kindle and smoke-test launch, note creation, edit/save, reader mode, mindmap mode, and KUAL relaunch.
- If releasing desktop editing, pair with Minfolio Desktop, verify an edit reaches each device, and stop the session to confirm the remote cache is removed.
