# Barcode Count

A phone-friendly web app for counting stock with barcodes:

1. **Scan** a barcode with the phone camera (or type it in manually)
2. **Assign a quantity** in the popup (quick buttons for 1 / 5 / 10 / 25, or type any number)
3. **Repeat** — scanning the same barcode again adds to its quantity
4. **Export** the list as a CSV file (or share/copy it) when you're done

The app is two files with no build step: [`index.html`](index.html) plus a vendored copy of the [html5-qrcode](https://github.com/mebjas/html5-qrcode) scanning library (`html5-qrcode.min.js`), so it has no CDN dependency and keeps working on flaky connections.

## Features

- Works on any modern phone browser (Android Chrome, iOS Safari) — nothing to install
- Reads common 1D and 2D barcodes: EAN, UPC, Code 128, Code 39, QR, and more
- Beep + vibration on each successful scan, with duplicate-scan debounce
- Running list with +/− quantity adjustment, tap-to-edit quantity, and delete per item
- Data is saved on the device (localStorage), so a page refresh doesn't lose your counts
- Export to CSV download, native share sheet, or clipboard
- Columns exported: `barcode, qty, first_scanned, last_scanned`

## Setup

Phone cameras only work on pages served over **HTTPS**, so the easiest way to use this is GitHub Pages:

1. In this repository, go to **Settings → Pages**
2. Under *Build and deployment*, set **Source** to *Deploy from a branch* and pick your branch (root folder)
3. Open the published URL on your phone and allow camera access when prompted

Any other HTTPS host (Netlify, Vercel, an internal server with TLS) works too. For local testing on a desktop, `http://localhost` is also allowed to use the camera.

## Usage tips

- Tap **Start camera** to begin scanning; tap again to pause it
- Scanning is paused automatically while the quantity popup is open
- Tap the quantity number on a list row to overwrite it (instead of adding to it)
- **Clear** wipes the list — export first if you need the data
