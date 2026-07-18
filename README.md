# Barscan

A phone-friendly web app for barcode stocktaking, backed by [Supabase](https://supabase.com):

1. **Log in** (or sign up) with an email and password
2. **Create a stocktake** and give it a name (e.g. "Warehouse A – July")
3. **Scan** barcodes with the phone camera (or type them in manually)
4. **Enter the quantity** for each scan — scanning the same barcode again adds to its quantity
5. **Leave and come back any time, on any device** — stocktakes are stored in the cloud and can be reopened and continued wherever you log in
6. **Export** a stocktake as a CSV file (or share/copy it) when you're done

## Features

- Works on any modern phone browser (Android Chrome, iOS Safari) — nothing to install
- Reads common 1D and 2D barcodes: EAN, UPC, Code 128, Code 39, QR, and more
- Beep + vibration on each successful scan, with duplicate-scan debounce
- Named stocktakes, each with its own running list: +/− quantity adjustment, tap-to-edit quantity, delete per item
- Real accounts (Supabase Auth) — data syncs across devices, and row-level security ensures each user can only ever read or modify their own stocktakes
- Export to CSV download, native share sheet, or clipboard
- Columns exported: `stocktake, barcode, qty, first_scanned, last_scanned`

## Files

| File | Purpose |
|---|---|
| `index.html` | The whole app (UI + logic) |
| `config.js` | Your Supabase project URL and anon key |
| `schema.sql` | Database tables, trigger, and row-level-security policies |
| `html5-qrcode.min.js` | Vendored barcode-scanning library |
| `supabase.min.js` | Vendored Supabase JS client |

Libraries are vendored (no CDN) so the app keeps loading on flaky connections.

## Supabase setup (once)

1. Create (or pick) a project at [supabase.com/dashboard](https://supabase.com/dashboard)
2. **SQL Editor → New query** → paste the contents of [`schema.sql`](schema.sql) → **Run**
3. **Project Settings → API**: copy the **Project URL** and the **anon public** key into [`config.js`](config.js)
4. Optional but recommended for warehouse use: **Authentication → Sign In / Up → Email** → turn **off** "Confirm email", so operators can sign up and start scanning immediately
5. The anon key is safe to ship in the frontend — access control is enforced by the row-level-security policies in `schema.sql`

## Hosting / deployment

The app is deployed to GitHub Pages automatically by a workflow on every push to `main`
([.github/workflows/deploy-pages.yml](.github/workflows/deploy-pages.yml)):

**https://jamesadmiraal-alt.github.io/desktop-tutorial/**

Phone cameras only work on pages served over **HTTPS**, which GitHub Pages provides. For local testing on a desktop, `http://localhost` is also allowed to use the camera. Until `config.js` is filled in, the deployed page shows a setup screen instead of the app.

## Usage tips

- Tap **Start camera** to begin scanning; tap again to pause it
- Scanning is paused automatically while the quantity popup is open
- Tap the quantity number on a list row to overwrite it (instead of adding to it)
- **Clear** wipes the current stocktake's items; deleting a stocktake from the list removes it entirely — export first if you need the data
- Use your phone browser's **Add to Home Screen** for an app-like icon
