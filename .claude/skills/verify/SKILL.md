---
name: verify
description: Build/launch/drive recipe for verifying the Barcode Count web app in this repo.
---

# Verifying the Barcode Count app

Static site, no build step. Serve and drive headless:

```bash
http-server . -p 8899 -s &   # http-server is installed globally
```

Drive with Playwright (`require('/opt/node22/lib/node_modules/playwright')`) using
`executablePath: '/opt/pw-browsers/chromium-1194/chrome-linux/chrome'` (the bare
`/opt/pw-browsers/chromium` dir has no binary — use the versioned dir).

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
