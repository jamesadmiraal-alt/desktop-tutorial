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
# node moved out of %LOCALAPPDATA% and IS on PATH now (verified 2026-09-29) —
# `node` alone works in a fresh shell; the full path is just belt and braces.
$node = "C:\Program Files\nodejs"                                  # node.exe, npm.cmd, npx.cmd
$test = "$env:LOCALAPPDATA\gantry-testing"                         # playwright + http-server live here
$env:NODE_PATH = "$test\node_modules"                              # so require('playwright') resolves

# serve the repo root
Start-Process "$node\node.exe" -ArgumentList "$test\node_modules\http-server\bin\http-server",".","-p","8899","-s" `
  -WorkingDirectory "c:\Users\james\OneDrive\Documents\GitHub\desktop-tutorial" -WindowStyle Hidden

& "$node\node.exe" yourscript.js     # require('playwright'); chromium.launch() finds its own browser
```

Playwright's Chromium is in `%LOCALAPPDATA%\ms-playwright`, deliberately outside
the repo so the Capacitor `package.json` stays untouched. It used to be found
automatically; as of playwright 1.63 the *headless shell* for the current build
is missing there while the full browser is present, so a bare
`chromium.launch()` dies with "Executable doesn't exist at
…chromium_headless_shell-1243…". Point at the full browser rather than running
`npx playwright install` (check the versioned dir name first — it changes):

```js
chromium.launch({ executablePath: process.env.LOCALAPPDATA +
  '/ms-playwright/chromium-1243/chrome-win64/chrome.exe' })
```

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

## Unit tests that need no browser

```
node scripts/test-barcode-export.js
node scripts/test-export-engine.js
```

Covers `barcode-export.js` — the export-time leading-zero rule and the line
merging that goes with it. It evaluates the real file with a stub `window`
(same global-assigning convention as `config.js`), so there is no second copy
of the rules to drift.

`test-export-engine.js` is the export templates' byte-identity proof: it keeps the
builders app.html used before templates VERBATIM as an oracle, reads the seeded
templates out of the migration's `$seed---
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
# node moved out of %LOCALAPPDATA% and IS on PATH now (verified 2026-09-29) —
# `node` alone works in a fresh shell; the full path is just belt and braces.
$node = "C:\Program Files\nodejs"                                  # node.exe, npm.cmd, npx.cmd
$test = "$env:LOCALAPPDATA\gantry-testing"                         # playwright + http-server live here
$env:NODE_PATH = "$test\node_modules"                              # so require('playwright') resolves

# serve the repo root
Start-Process "$node\node.exe" -ArgumentList "$test\node_modules\http-server\bin\http-server",".","-p","8899","-s" `
  -WorkingDirectory "c:\Users\james\OneDrive\Documents\GitHub\desktop-tutorial" -WindowStyle Hidden

& "$node\node.exe" yourscript.js     # require('playwright'); chromium.launch() finds its own browser
```

Playwright's Chromium is in `%LOCALAPPDATA%\ms-playwright`, deliberately outside
the repo so the Capacitor `package.json` stays untouched. It used to be found
automatically; as of playwright 1.63 the *headless shell* for the current build
is missing there while the full browser is present, so a bare
`chromium.launch()` dies with "Executable doesn't exist at
…chromium_headless_shell-1243…". Point at the full browser rather than running
`npx playwright install` (check the versioned dir name first — it changes):

```js
chromium.launch({ executablePath: process.env.LOCALAPPDATA +
  '/ms-playwright/chromium-1243/chrome-win64/chrome.exe' })
```

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

## Unit tests that need no browser

```
node scripts/test-barcode-export.js
node scripts/test-export-engine.js
```

Covers `barcode-export.js` — the export-time leading-zero rule and the line
merging that goes with it. It evaluates the real file with a stub `window`
(same global-assigning convention as `config.js`), so there is no second copy
 block (and checks schema.sql has the same
block), and fails if any seeded template's file differs from the old one by a byte.

## Driving code that lives inside the IIFE

`app.html` and `admin.html` each wrap their whole script in `(function () { … })()`,
so NOTHING is reachable from `page.evaluate` — not `doExport`, not `currentOrg`,
not `sb`. Calling one gives "X is not defined"; assigning one is worse, because
it silently creates a *global* `currentOrg` the closure never reads and the
handler then throws on `null`.

Cheapest way through: copy the page to `app-test.html`, splice a hook block in
just before the closing `})();`, serve that, delete it after. The hook's setters
are defined INSIDE the closure, so the real handlers run against stubs:

```js
window.__T = {
  doExport: function () { return doExport(); },
  setOrg: function (o) { currentOrg = o; },
  setSb: function (x) { sb = x; },
  onDownload: function (fn) { downloadCsv = fn; },
  stubItems: function (items) { fetchTakeItems = function (id, cb) { cb(items); }; },
};
```

That exercises the shipping code instead of a re-implementation of it. Never
commit the instrumented copy.

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
