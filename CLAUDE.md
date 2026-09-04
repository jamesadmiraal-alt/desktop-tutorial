# Gantry — project guide for Claude Code

Gantry is a phone-first barcode stocktaking SaaS for hospitality (bars, venues).
Static frontend, Supabase backend, Stripe Payment Links for billing.

## Architecture

- **No build step.** Plain HTML/CSS/JS, libraries vendored into the repo (no CDNs).
- `index.html` — marketing landing page (features, POS interest form, pricing: Trial /
  Single-venue $29/mo or $290/yr / Multi-venue $59/mo or $590/yr).
- `privacy.html`, `terms.html` — static legal pages, linked from the site footer, the
  signup form and Account. **Both are marked as drafts pending legal review** — say so
  if asked, and don't quietly remove the banner.
- `app.html` — the whole app: auth, stocktake list, scanner, account/subscription views.
  All views live in one file, toggled via `showView()`.
- `config.js` — Supabase URL + anon key, Stripe Payment Link URLs (`upgradeUrls`, keyed by
  currency). The anon key and payment links are safe to commit. **Never commit `sk_` Stripe
  keys or `service_role` keys.**
- `schema.sql` — idempotent; the whole DB: `organisations` (`plan_tier`,
  `stripe_customer_id`, `country`, `concurrent_seats`), `profiles`, `memberships`,
  `venues`, `locations`, `stocktakes`, `stocktake_items`, `audit_log`, triggers, RLS.
  **NOTE: parts of the older text in this file predate the org model** — there is no
  `is_pro` column and no free tier; billing is org-scoped, not per-user.
- **Plan tiers** (`organisations.plan_tier`): `trial` → `single` / `multi`, plus
  `pending`, which is now only a **lapsed** subscription or an org created before the
  trial existed. `create_organisation()` starts a new org on `trial` *with* a venue and
  a `Main` location — `pending` deliberately had neither, which is what made it a
  paywall rather than a trial.
- **The trial cap is 5 products per stocktake**, unlimited stocktakes, exports never
  capped. Enforced by the `enforce_trial_scan_limit()` BEFORE INSERT trigger — a
  trigger and NOT an RLS policy, because `add_stocktake_item()` is `security definer`
  and bypasses policies, so a policy would miss the app's own scan path. The exception
  message is prefixed `Trial limit reached`; `app.html` matches on that prefix to raise
  the upgrade dialog instead of a red toast, so keep the prefix if you reword it.
- **Marketing consent**: the signup box is **pre-ticked** (opt-out, by request).
  `handle_new_user()` records what was actually submitted plus a timestamp.
  `profiles.marketing_opt_in` is NOT in the client-writable column GRANT — the only way
  to change it is `set_marketing_opt_in()`, which is self-only and is what the Account →
  Email toggle calls. Don't "simplify" that by widening the GRANT.
- Checkout currency: operators pick a country at signup, or change it later in 👤 Account via
  the "Change region" confirm dialog (not an always-open `<select>` — that's deliberate, see
  below). Stored as `profiles.country`. `app.html`'s `COUNTRY_CURRENCY` maps it to a currency,
  which selects which entry of `config.js`'s `upgradeUrls` map `goUpgrade()` opens (falls back
  to `DEFAULT_CURRENCY`, currently AUD — the only currency guaranteed to have real links — if
  the mapped currency has none configured yet). `profiles.country` is client-writable — see
  the column-scoped GRANT in `schema.sql` — but `is_pro`/`stripe_customer_id` are not.
- Country changes are rate-limited to once per 30 days — a `before update` trigger
  (`enforce_country_cooldown` in `schema.sql`) stamps `profiles.country_changed_at` and
  rejects a change if the last one was too recent. This is enforced in Postgres, not just the
  app, specifically so a Free user can't hop to a cheaper-currency country right before
  upgrading and hop back after. `app.html`'s `countryChangeEligible()` is only a client-side
  heads-up (shows the actual next-eligible date before bothering to make a request) — the
  trigger is the real boundary.
- `supabase/functions/super-stripewebhooks/index.ts` — Deno edge function that sets
  `organisations.plan_tier` on `checkout.session.completed` /
  `customer.subscription.deleted` / `customer.subscription.updated`, creates the org's
  first venue+location if missing, and sends the welcome email. Stripe calls it
  unauthenticated (JWT verification OFF — it verifies its own HMAC signature instead),
  which is the opposite of every other function here, so its deploy needs
  `--no-verify-jwt`. It DOES call Stripe's API outbound (to read the purchased price),
  so it needs `STRIPE_SECRET_KEY` as well as `STRIPE_WEBHOOK_SECRET`.
  **The folder name and the deployed slug must stay identical.** They disagreed until
  2026-09-02 (folder `stripe-webhook`, slug `super-stripewebhooks`) and because the CLI
  deploys by folder name, a deploy reported success while creating a second function
  nothing called and leaving the live one on old code. Renaming either side re-arms
  that trap.
- `supabase/functions/create-portal-session/index.ts` and `.../delete-account/index.ts` —
  the opposite trust model from the webhook: JWT verification stays ON (they act on behalf
  of whoever calls them, identified from that caller's own session), and they *do* call
  Stripe's API outbound (open the Customer Portal; cancel a subscription immediately before
  deleting the account), using a new `STRIPE_SECRET_KEY` secret. Account deletion relies on
  the existing cascade-delete FKs (`profiles`/`stocktakes`/`stocktake_items` → `auth.users`)
  already in `schema.sql` — no separate cleanup code needed. See STRIPE-SETUP.md §7-10.
- Barcode scanning: native `BarcodeDetector` when available (Android Chrome), else the
  vendored zxing-wasm ponyfill (`barcode-detector.iife.js` + `zxing_reader.wasm`).
  Do not reintroduce a `qrbox`-style scan region — it silently breaks QR decoding.
  **Which formats are decoded is an org setting**, not a constant: `activeFormats()`
  builds the list from `organisations.scan_barcodes` / `scan_qr` at detector-build time,
  and `makeDetector()` must keep reading it there so a live camera picks up a change.
  Defaults are **barcodes on, QR off** — a wine bottle's marketing QR otherwise wins the
  frame over its retail barcode. A missing value must never be read as "both on".
- `isPlausibleBarcode()` rejects a glued pair of scans, and its test is **digits-only**
  over 18 characters. A plain length cap looks equivalent and is not: a QR payload is
  usually a URL, so a length cap silently throws away every QR decode. That interaction
  shipped once already.
- Light/dark mode (`app.html` only — `index.html` doesn't have a toggle): every themed
  color is a CSS custom property on `:root`, overridden under `:root[data-theme="light"]`
  (dark is the default/original palette). New UI must use `var(--token)`, never a raw hex,
  or it'll only render correctly in one theme. The scanner viewport (`#reader-wrap` and
  its children) is a deliberate exception — always dark in both themes, since it sits
  against a live camera feed. A tiny synchronous script at the very top of `<head>` sets
  `data-theme` before first paint (avoids a flash of the wrong theme); `applyTheme()` in
  the main script handles the toggle click, `localStorage` persistence, `<meta
  name=theme-color>`, and the native status bar style. Default is the OS's
  `prefers-color-scheme` until the operator explicitly toggles, after which their choice
  always wins over the OS.

## Native apps (iOS/Android)

- Capacitor wraps `app.html` for native builds — see `NATIVE-SETUP.md` for the full
  runbook. This layer has its own `package.json`/`node_modules` (Capacitor CLI +
  plugins) but does **not** give the web app a build step: `index.html`/`app.html`
  still deploy to GitHub Pages exactly as committed.
- `scripts/prepare-native.js` copies `app.html` → `native-www/index.html` (native
  always loads `index.html` from its `webDir`, and root `index.html` has to stay the
  marketing page for the web deploy) plus the shared vendored assets. Generated, not
  committed — regenerate with `npm run prepare-native` or `npm run sync:android`/`sync:ios`.
- `capacitor.js` + `capacitor-*-plugin.js` are vendored `@capacitor/*` browser builds
  (same convention as `supabase.min.js`), loaded directly by `app.html` and inert on
  the web deploy since `Capacitor.isNativePlatform()` is `false` there.
- Native-only behavior in `app.html` (Stripe checkout via in-app browser, back-button
  handling, camera release on backgrounding, resume-triggered `is_pro` refresh) is all
  guarded on `isNative` — search for that variable before changing checkout/back-nav/
  scanner-lifecycle code so you don't miss the native branch.
- `android/` and `ios/` are committed platform projects (build artifacts gitignored).
  `capacitor.config.json`'s `appId` is a placeholder — must change before store submission.

## Deployment

- Push to `main` → GitHub Actions (`.github/workflows/deploy-pages.yml`) deploys to
  GitHub Pages: https://jamesadmiraal-alt.github.io/desktop-tutorial/
- The Pages environment only accepts deploys from `main`.
- Supabase project: `vfixdchbkmqryfhirphx` (auth + Postgres + edge function).
- Stripe is in **test mode**; payment links live in `config.js`. See `STRIPE-SETUP.md`
  for the full billing wiring (products, links, webhook, secrets).

## Conventions & gotchas

- Pricing appears in SIX places — landing page, account view (three plan cards), the
  trial wall, the payment-pending screen, `terms.html`, and README — keep them in sync
  (grep for `$29` / `$290` / `$59`). The in-app prices ARE re-rendered per currency by
  `renderUpgradePrices()` from `config.js`; the static markup is the AUD fallback, and
  the README/terms figures are reference text only.
- Verify changes by driving the app headless with Playwright; the repo verify skill at
  `.claude/skills/verify/SKILL.md` documents the recipe, including how to fake a camera
  stream (y4m with a QR) to test real barcode decoding end to end.
- `client_reference_id` + `prefilled_email` are appended to payment links by the app —
  the webhook depends on this to match the paying user.
- **Users vs seats is the pricing model, and the words matter.** Two separate things,
  and users conflated them until the copy was fixed on 2026-09-01: **how many people
  you set up** is unlimited and free on Multi-venue, while **how many can be counting
  at the same time** is what's billed ($29/mo each beyond the owner). Say "people" and
  "at the same time" in anything user-facing; "concurrent user" and "seat" are the
  billing terms and belong in Stripe and in code, not on screen. The column stays
  `concurrent_seats` — this is a copy convention, not a rename.
  One sentence lives in THREE places and schema.sql says so: `add_team_member()`'s
  exception, `create-team-member`'s 403 body, and the Team view in app.html. Reword all
  three together, and a schema reword needs a migration since the string is in the DB.
- Password minimum is `PASSWORD_MIN` in app.html — used by signup, password reset AND
  the hint on the form. Supabase Auth has its own minimum (Dashboard → Auth → Password
  policy); raising one without the other means the server accepts what the app rejects.
- Email: `supabase/functions/_shared/email.ts` is a provider-agnostic sender chosen by
  which secret exists, and it returns `{sent:false}` rather than throwing when none is
  configured — so **every caller must treat a failed send as non-fatal**, and all five
  do (the Stripe webhook especially: Stripe retries a non-2xx, so a bounced email must
  never re-run a payment handler). The same module owns `brandedHtml()` and the
  customer-facing URLs (`SITE`/`APP_URL`/`ADMIN_URL`) — import them, don't re-declare a
  URL in a function. Auth email (confirm signup, password reset) is separate and comes
  from Supabase's own mailer. See `EMAIL-SETUP.md`; **none of it delivers until
  gantrystocktake.com is verified with a provider.**
- **Customer-facing links use `gantrystocktake.com`, never `jamesadmiraal-alt.github.io`.**
  Both hosts serve the same files; the github.io one is where the site is *built* and
  should never be what a customer is shown. That means email bodies, `app.html`'s
  `SITE_URL`/`ADMIN_URL`, and `create-portal-session`'s `RETURN_URL`. Still on github.io
  and needing a Stripe Dashboard edit: the 10 Payment Links' after-payment redirect.
- Email HTML is table-based with inline styles — no flexbox, no grid, no `<style>` block,
  no classes, and no `var()`. Outlook's Word engine ignores modern CSS and Gmail strips
  `<style>`. The header mark is a PNG (`icons/email-mark.png`, generated from
  `icons/gantry-mark.svg`) because email clients don't render SVG, and it is written to
  degrade gracefully because most clients block remote images by default.
- Export shape comes from `organisations.export_format`, set once per org by the owner in
  admin.html. `'standard'` is `barcode,count` with no header row and **no BOM** — verified
  against a real Bepoz importer after a trial where Gantry's own 5-column CSV matched no
  products at all. `'bepoz'` is an alias for the same builder (pre-rename value); deleting
  it from `EXPORT_FORMATS` makes such a row fall back silently to the 5-column file, which
  is that original bug returning invisibly. The BOM is per-format on purpose: Excel needs it
  for `'full'`, and it corrupts the first barcode for `'standard'`.
- Quantity precision is 2 dp in THREE places — the numpad's input guard, `QTY_DP` in
  app.html, and `qty numeric(12,2)` in schema.sql. Anything finer needs all three.
