---
name: verify
description: Build/launch/drive recipe for verifying the Barcode Count web app in this repo.
---

# Verifying the Gantry app

Static site, no build step. Serve it, then drive it headless.

## Windows (james's laptop)

Node/Playwright are NOT on the default PATH here and there's no global
`http-server`. Everything lives under `%LOCALAPPDATA%`, installed portable (no
admin). Node is on the *user* PATH, so a fresh terminal has it, but a
already-open shell may not — call it by full path to be safe:

```powershell
$node = "$env:LOCALAPPDATA\nodejs\node-v24.19.0-win-x64"          # node.exe, npm.cmd, npx.cmd
$test = "$env:LOCALAPPDATA\gantry-testing"                         # playwright + http-server live here
$env:NODE_PATH = "$test\node_modules"                              # so require('playwright') resolves

# serve the repo root
Start-Process "$node\node.exe" -ArgumentList "$test\node_modules\http-server\bin\http-server",".","-p","8899","-s" `
  -WorkingDirectory "c:\Users\james\OneDrive\Documents\GitHub\desktop-tutorial" -WindowStyle Hidden

& "$node\node.exe" yourscript.js     # require('playwright'); chromium.launch() finds its own browser
```

Playwright's Chromium is in `%LOCALAPPDATA%\ms-playwright` and is found
automatically — do NOT pass `executablePath` on Windows. Deliberately installed
outside the repo so the Capacitor `package.json` stays untouched.

Kill the server when done: `Get-Process node | Stop-Process` (nothing else here
runs node).

## Typechecking the Edge Functions

Worth doing before every `functions deploy` — the deploy itself does NOT
typecheck, so a type error ships silently and only surfaces as a 500 in
production. It found a real one: `stripe-webhook`'s `db()` helper was missing its
`= {}` default, which broke venue creation on every checkout.

Deno is at `%LOCALAPPDATA%\denobin\deno.exe` (not on PATH). It must run from a
directory **outside the repo**: the repo root has a Capacitor `package.json` with
no `@supabase/supabase-js` in it, so `npm:` specifiers fail to resolve there.

```powershell
$tc = "$env:TEMP\gantry-tc"
Remove-Item $tc -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force "$tc\functions" | Out-Null
Copy-Item "<repo>\supabase\functions\*" "$tc\functions" -Recurse -Force
# deno.json must be written WITHOUT a BOM — Out-File -Encoding utf8 adds one in
# PS 5.1 and Deno rejects the file with "Unexpected token on line 1 column 1".
[IO.File]::WriteAllText("$tc\deno.json", '{ "nodeModulesDir": "auto" }')
Set-Location $tc
& "$env:LOCALAPPDATA\denobin\deno.exe" check functions/*/index.ts
```

Exit 0 means clean. Note `deno check` writes its progress lines to stderr, so
PowerShell surfaces them as NativeCommandError noise even on success — read the
exit code, not the presence of red text.

## Linux sandbox

`require('/opt/node22/lib/node_modules/playwright')` with
`executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome'` (the bare
`/opt/pw-browsers/chromium` dir has no binary — use the versioned dir), and
`http-server` is installed globally.

## What can't be driven without credentials

Everything behind login — the stocktake list, 👤 Account, the Team view,
admin.html — needs a real Supabase session, so an unauthenticated run only
reaches `#auth-view`. That still catches the most common regression (a syntax
error in the one big inline script: watch `pageerror`/`console` and assert the
new elements exist). To exercise logged-in flows, either use a throwaway test
account or stub `window.sb` before the app's script runs and drive the handlers
directly.

## Flows worth driving

- Manual entry path (`#manual-input` + `#manual-add`) exercises the same
  qty-dialog → list → localStorage flow as a camera scan.
- CSV export: use Playwright `acceptDownloads` + `waitForEvent('download')`,
  read the file back; check quoting with a code like `WEIRD,"CODE"`.
- Real camera decode: launch Chromium with
  `--use-fake-ui-for-media-stream --use-fake-device-for-media-stream
  --use-file-for-fake-video-capture=<file>.y4m` and grant the `camera`
  permission on the context. Generate the y4m by rendering a QR matrix
  (npm `qrcode`, `QRCode.create(...).modules`) straight into raw
  YUV4MPEG2 C420 frames in Node — Playwright's bundled ffmpeg cannot
  read PNG inputs, so don't go via ffmpeg.

## Gotchas

- When faking Supabase at the HTTP boundary (`page.route('**/rest/v1/**')`),
  return a **JSON array** for every select — including `.single()`/
  `.maybeSingle()`. The vendored `supabase.min.js` implements those
  client-side (`isMaybeSingle && Array.isArray(r) && (r = r.length===1 ?
  r[0] : null)`); it does NOT send
  `Accept: application/vnd.pgrst.object+json`. So "no rows" is a plain
  `200 []`, never a `406`/`PGRST116`. Faking the 406 invents an error the
  real backend cannot produce, and returning a bare object makes the client
  hand `null` to code that expected a row — both look like app bugs.
- Seed a session by writing `sb-<project-ref>-auth-token` into localStorage in
  an `addInitScript` (a hand-built JWT with a future `exp` is enough — nothing
  verifies the signature client-side). That gets you past `#auth-view` without
  real credentials.

- **Asserting export bytes: never use `Blob.text()` / `File.text()`.** Both run
  the spec's "UTF-8 decode", which *strips a leading BOM* — so a `text()`-based
  assertion reports "no BOM" whether or not one is there, in both directions.
  Read raw bytes instead: `fs.readFileSync(await download.path())` for a
  download, `new Uint8Array(await file.arrayBuffer())` for a shared `File`.
  This matters because the BOM is load-bearing in opposite directions per
  format — Excel needs it for the Gantry CSV's accented venue names, and it
  corrupts the first barcode of a Bepoz import (see `EXPORT_FORMATS` in
  `app.html`).
- Exporting **changes the stocktake's status to Completed**, which re-renders
  Home and moves the row out of `#stocktake-list-ready`. A second action on the
  same stocktake in one test has to re-find it (`#home-view .more`), or it waits
  forever on a selector that was correct a moment earlier.
- unpkg/CDNs are blocked by the sandbox proxy; registry.npmjs.org is
  direct-allowed, so vendor libraries via `npm pack`.
- Don't restrict the scanner's `qrbox` to a wide strip — it silently
  crops QR codes and they never decode (this bit us once).
