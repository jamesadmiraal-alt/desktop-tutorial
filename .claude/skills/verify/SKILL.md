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

- unpkg/CDNs are blocked by the sandbox proxy; registry.npmjs.org is
  direct-allowed, so vendor libraries via `npm pack`.
- Don't restrict the scanner's `qrbox` to a wide strip — it silently
  crops QR codes and they never decode (this bit us once).
