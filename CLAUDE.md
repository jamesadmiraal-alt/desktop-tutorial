# Barscan — project guide for Claude Code

Barscan is a phone-first barcode stocktaking SaaS for hospitality (bars, venues).
Static frontend, Supabase backend, Stripe Payment Links for billing.

## Architecture

- **No build step.** Plain HTML/CSS/JS, libraries vendored into the repo (no CDNs).
- `index.html` — marketing landing page (features, pricing: Free vs Pro $29/mo or $290/yr).
- `app.html` — the whole app: auth, stocktake list, scanner, account/subscription views.
  All views live in one file, toggled via `showView()`.
- `config.js` — Supabase URL + anon key, Stripe Payment Link URLs. The anon key and
  payment links are safe to commit. **Never commit `sk_` Stripe keys or `service_role` keys.**
- `schema.sql` — idempotent; the whole DB: `profiles` (with `is_pro`, `stripe_customer_id`),
  `stocktakes`, `stocktake_items`, triggers, RLS. The free-plan limit (3 distinct products
  per stocktake) is enforced BOTH client-side and by the RLS insert policy.
- `supabase/functions/stripe-webhook/index.ts` — Deno edge function (deployed in Supabase
  under the name **`super-stripewebhooks`**, note the different name!) that flips
  `profiles.is_pro` on `checkout.session.completed` / `customer.subscription.deleted`.
- Barcode scanning: native `BarcodeDetector` when available (Android Chrome), else the
  vendored zxing-wasm ponyfill (`barcode-detector.iife.js` + `zxing_reader.wasm`).
  Do not reintroduce a `qrbox`-style scan region — it silently breaks QR decoding.

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

- Pricing appears in FOUR places — landing page, account view, upgrade dialog, README —
  keep them in sync (grep for `$29` / `$290`).
- Verify changes by driving the app headless with Playwright; the repo verify skill at
  `.claude/skills/verify/SKILL.md` documents the recipe, including how to fake a camera
  stream (y4m with a QR) to test real barcode decoding end to end.
- `client_reference_id` + `prefilled_email` are appended to payment links by the app —
  the webhook depends on this to match the paying user.
- Free-plan gate: `FREE_LIMIT` in app.html AND the `< 3` in schema.sql's insert policy.
  Change both together.
