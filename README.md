# Barscan

A phone-friendly web app for barcode stocktaking:

1. **Log in** (or sign up) with a username and password
2. **Create a stocktake** and give it a name (e.g. "Warehouse A – July")
3. **Scan** barcodes with the phone camera (or type them in manually)
4. **Enter the quantity** for each scan — scanning the same barcode again adds to its quantity
5. **Leave and come back any time** — stocktakes are saved under their name and can be reopened and continued
6. **Export** a stocktake as a CSV file (or share/copy it) when you're done

The app is two files with no build step: [`index.html`](index.html) plus a vendored copy of the [html5-qrcode](https://github.com/mebjas/html5-qrcode) scanning library (`html5-qrcode.min.js`), so it has no CDN dependency and keeps working on flaky connections.

## Features

- Works on any modern phone browser (Android Chrome, iOS Safari) — nothing to install
- Reads common 1D and 2D barcodes: EAN, UPC, Code 128, Code 39, QR, and more
- Beep + vibration on each successful scan, with duplicate-scan debounce
- Named stocktakes, each with its own running list: +/− quantity adjustment, tap-to-edit quantity, delete per item
- Per-user accounts — each user sees only their own stocktakes
- Export to CSV download, native share sheet, or clipboard
- Columns exported: `stocktake, barcode, qty, first_scanned, last_scanned`

## Important: where the data lives

Accounts and stocktake data are stored **on the device, in that browser** (localStorage) — there is no server. That means:

- A stocktake must be continued on the **same phone and browser** where it was started
- Accounts are per-device: signing up on one phone does not create the account on another
- This separates operators sharing a device, but it is **not** real security — anyone with full access to the device storage could read the data
- Clearing the browser's site data deletes accounts and stocktakes — **export CSVs before doing that**

If you need multi-device sync or real authentication, the app needs a small backend (e.g. Supabase or Firebase) — a natural next step.

## Hosting / deployment

The app is deployed to GitHub Pages automatically by a workflow on every push to `main`
([.github/workflows/deploy-pages.yml](.github/workflows/deploy-pages.yml)):

**https://jamesadmiraal-alt.github.io/desktop-tutorial/**

Phone cameras only work on pages served over **HTTPS**, which GitHub Pages provides. For local testing on a desktop, `http://localhost` is also allowed to use the camera.

## Usage tips

- Tap **Start camera** to begin scanning; tap again to pause it
- Scanning is paused automatically while the quantity popup is open
- Tap the quantity number on a list row to overwrite it (instead of adding to it)
- **Clear** wipes the current stocktake's items; deleting a stocktake from the list removes it entirely — export first if you need the data
- Use your phone browser's **Add to Home Screen** for an app-like icon
