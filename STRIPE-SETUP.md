# Connecting Stripe to Gantry (test mode)

Gantry uses **Stripe Payment Links** for checkout and a **Supabase Edge Function**
webhook to activate a paid plan automatically after payment. No server of your own
is needed.

Billing is **organisation-scoped**, not per-user (see the org-model planning doc):
an organisation is on the **Free**, **Single-venue** ($29/mo flat), or **Multi-venue**
($59/mo base + $29/mo per extra concurrent user beyond the owner, via Stripe's
native graduated pricing — venues/locations themselves are unlimited and free)
plan, each also offered **monthly or annually** (a "Bill annually" toggle
in the app swaps between them — annual is priced at 10x the monthly amount, i.e.
2 months free, matching the app's copy). Everything below happens in the Stripe
**sandbox/test** dashboard first. When you go live, repeat the same steps in live
mode and swap the URLs/secrets.

## 1. Create the two products and their prices (Stripe Dashboard)

**Note on naming**: the product names below ("Barscan Single-venue" etc.)
match what's actually live in the Stripe Dashboard today — this doc's
instructions describe the existing setup, they don't rename it. Renaming
the live Stripe products to "Gantry Single-venue"/"Gantry Multi-venue" (and
updating this doc to match) is a separate, deliberate step — Stripe product
names are cosmetic (shown on invoices/receipts) and don't affect the price
IDs or Payment Links already wired into `config.js`, so there's no urgency,
but do it in the Stripe Dashboard directly rather than just editing this
file if you want the rebrand to be complete end to end.

Gantry picks a Stripe Payment Link based on the organisation's country (set when
the org is created, editable by the owner in 👤 Account → Change region) — see
`COUNTRY_CURRENCY` in `app.html`. Today that maps to four currencies: **AUD**
(default/home currency), **USD**, **GBP**, **EUR**. Two tiers × four currencies ×
two billing periods = **16 prices** total — tedious, but each one is quick.

1. Stripe Dashboard → **Product catalog** → **+ Add product** → create
   **Barscan Single-venue**. Add **one flat recurring price per currency per
   period** (8 prices: 4 currencies × monthly/annual) — reuse whatever amounts
   make sense per market, they don't need to be an exact conversion:
   | Currency | Monthly | Annual |
   |---|---|---|
   | AUD | $29 | $290 |
   | USD | $27 | $270 |
   | GBP | £25 | £250 |
   | EUR | €27 | €270 |
2. **+ Add product** again → create **Barscan Multi-venue**. For each currency
   **and** each period (8 more prices), add a recurring price using Stripe's
   tiered/graduated pricing (pricing model → "Tiered", tiers mode →
   "Graduated"), with exactly two tiers:
   - **Tier 1**: up to **1** unit, **flat fee** — $59/mo or $590/yr (AUD; scale
     the other currencies the same way you did for Single-venue above)
   - **Tier 2**: up to **∞**, **per-unit** — $29/mo or $290/yr

   This produces a total of `base + perSeat × (quantity − 1)` — quantity
   tracks 1 (the always-free owner) plus however many extra concurrent
   seats the owner has purchased, kept in sync by the `set-seat-count`
   Edge Function (§9) whenever the owner changes it in admin.html.
3. (The old single "Barscan Pro" product from before the org-tier rework, if it
   still exists, isn't used by any current code — safe to leave alone or archive.)

## 2. Create a Payment Link per price (16 total)

For **each** price: **Payment links** → **+ New** → pick the price, then under
**After payment** choose **Don't show confirmation page** and set the redirect
URL to:

```
https://gantrystocktake.com/app.html?upgraded=1
```

**The existing 10 links still point at `jamesadmiraal-alt.github.io`.** Both
hosts serve the same files, so checkout still works — but this is the URL a
customer watches their browser land on straight after paying, and it should be
the brand rather than the build host. Updating it is a per-link Dashboard edit
with no code change; `?upgraded=1` is handled identically on either host.

Copy each resulting link (`https://buy.stripe.com/test_...`). Keep track of which
is which (currency/tier/period) — you'll need that mapping for both steps below.

**Don't skip the redirect.** If a link is left on Stripe's default
"Thanks for subscribing" confirmation page, the operator is stranded there after
paying — the app never sees `?upgraded=1`, so it never posts the confirmation
toast or re-checks the plan, and they have to find their own way back to Gantry.
The redirect is per-link, so a link added later can silently miss it while every
other link works. Worth re-checking all 16 whenever checkout "feels" wrong.

### Also turn on billing address collection

On each link, under **Options → Collect customer addresses**, set **Billing
address** to **Required**. Two reasons, and neither is optional in practice:

- **A tax invoice needs the buyer's address.** Venues hand invoices to their
  bookkeeper, and one without an address gets sent back. Stripe puts the
  collected address on the invoice automatically.
- **The country Gantry holds is not the country they trade in.** `profiles.country`
  is whatever the operator picked to set their *currency*, and it can be changed.
  It was never meant to be a billing address.

The address lands on the Stripe Customer, so nothing changes in the app or the
database, and customers can update it themselves in the Customer Portal
(section 10). This is also per-link, so a link added later misses it — the same
trap as the redirect above.

**Stripe Tax is deliberately not enabled.** It would calculate and show GST/VAT
correctly per country, which is the right end state, but it requires a tax
registration in each jurisdiction you collect for. That's a business decision to
make once EU/UK volume is real, not a setup step to tick now.

## 3. Put the links into the app

In `config.js`'s `upgradeUrls`, keyed by currency → tier → period (leave a
period's `link` as `''` until you've created that price/link — the app falls
back to AUD, the already-configured default):

```js
upgradeUrls: {
  AUD: {
    single: {
      symbol: 'A$',
      monthly: { link: 'PASTE HERE', price: '29' },
      annual:  { link: 'PASTE HERE', price: '290' }
    },
    multi: {
      symbol: 'A$',
      monthly: { link: 'PASTE HERE', basePrice: '59', perSeatPrice: '29' },
      annual:  { link: 'PASTE HERE', basePrice: '590', perSeatPrice: '290' }
    }
  },
  USD: { /* same shape */ }, GBP: { /* same shape */ }, EUR: { /* same shape */ }
}
```

The app automatically appends `client_reference_id` (the **organisation's** id —
not a user id) and `prefilled_email` to these links, which is how the webhook
knows which org to upgrade.

## 4. Fill in the webhook's price → tier map

`supabase/functions/super-stripewebhooks/index.ts` has a `PRICE_TIER_MAP` near the top,
currently empty (placeholder). For each of the 16 prices created in §1, find its
Price ID (Stripe Dashboard → Product catalog → the product → the price → copy
the ID, looks like `price_1AbCdE...`) and add an entry — the map only needs to
know the **tier**, not the billing period (monthly/annual are just two prices
that both mean the same tier; Stripe handles the amount/interval on its own):

```ts
const PRICE_TIER_MAP: Record<string, "single" | "multi"> = {
  "price_...AUD_SINGLE_MONTHLY...": "single",
  "price_...AUD_SINGLE_ANNUAL...":  "single",
  "price_...AUD_MULTI_MONTHLY...":  "multi",
  "price_...AUD_MULTI_ANNUAL...":   "multi",
  "price_...USD_SINGLE_MONTHLY...": "single",
  "price_...USD_SINGLE_ANNUAL...":  "single",
  "price_...USD_MULTI_MONTHLY...":  "multi",
  "price_...USD_MULTI_ANNUAL...":   "multi",
  "price_...GBP_SINGLE_MONTHLY...": "single",
  "price_...GBP_SINGLE_ANNUAL...":  "single",
  "price_...GBP_MULTI_MONTHLY...":  "multi",
  "price_...GBP_MULTI_ANNUAL...":   "multi",
  "price_...EUR_SINGLE_MONTHLY...": "single",
  "price_...EUR_SINGLE_ANNUAL...":  "single",
  "price_...EUR_MULTI_MONTHLY...":  "multi",
  "price_...EUR_MULTI_ANNUAL...":   "multi",
};
```

Update this (and redeploy, §7) every time you add a new price/Payment Link.

## 5. Deploy the webhook (Supabase)

The function lives at `supabase/functions/super-stripewebhooks/index.ts` and is
deployed under that same slug.

**The name is historical, and until 2026-09-02 the folder and the deployed slug
disagreed** — the folder was `stripe-webhook` while the live function (the one
Stripe actually calls) was `super-stripewebhooks`. Since the CLI deploys by
folder name, `supabase functions deploy stripe-webhook` created a *second*
function that nothing called, while the real one stayed on the old code — a
deploy that reports success and changes nothing. The folder was renamed to match
so that can't happen again. **Don't rename either one back.**

It makes one outbound Stripe API call per checkout (to determine which tier was
purchased), so it needs `STRIPE_SECRET_KEY` — see §8, which you likely already
added for `create-portal-session`/`delete-account`; Supabase secrets are
project-wide, so nothing extra to do there if so. It also *optionally* sends the
"thanks for upgrading" email — see [`EMAIL-SETUP.md`](EMAIL-SETUP.md); with no
mail provider secret the checkout works exactly as before and the send is
skipped.

**CLI:**

```sh
supabase functions deploy super-stripewebhooks --no-verify-jwt --use-api --project-ref vfixdchbkmqryfhirphx
```

`--no-verify-jwt` is specific to this function: Stripe calls it unauthenticated
and it verifies its own HMAC signature instead. Every other function keeps JWT
verification ON. `--use-api` bundles server-side, which is what you want when
Docker isn't installed.

**Or the dashboard editor:** Supabase Dashboard → **Edge Functions** →
`super-stripewebhooks` → paste, deploy. Note it now imports
`../_shared/email.ts`, so the editor needs both files, and JWT verification must
stay **disabled** for this one.

## 6. Point Stripe at the webhook

1. Stripe Dashboard → **Developers** → **Webhooks** → **+ Add endpoint** (or edit
   the existing one if you already had it from before the org-tier rework)
2. Endpoint URL — the path is the deployed **slug** (see §5 on the name):
   ```
   https://vfixdchbkmqryfhirphx.supabase.co/functions/v1/super-stripewebhooks
   ```
   If Stripe currently points somewhere else, that endpoint is not the function
   being maintained. Check it before assuming a webhook problem is a code
   problem.
3. Events to send: `checkout.session.completed`, `customer.subscription.deleted`,
   and **`customer.subscription.updated`** (new — covers a tier change made
   directly on a subscription, e.g. by you in the dashboard)
4. Copy the **Signing secret** (`whsec_...`)
5. Supabase Dashboard → **Edge Functions** → **Secrets** → add/confirm
   `STRIPE_WEBHOOK_SECRET` = that `whsec_...` value

## 7. Test the checkout flow

1. In the app, sign in as an organisation **owner** on the **Free** plan and tap
   👤 Account → **Single-venue** or **Multi-venue**
2. On the Stripe test checkout, pay with card `4242 4242 4242 4242`, any future
   expiry, any CVC
3. You're redirected back to the app with a "Payment received" message
4. Within a few seconds the webhook flips the organisation's plan — open
   👤 Account and the matching plan badge should appear
5. For Multi-venue specifically: in `admin.html`'s "How many can count at once"
   card, set the extra people to 1 and click Update — check the Stripe
   Dashboard's subscription afterward and confirm its quantity is 2
   (the owner's included slot + 1 purchased)
6. To test cancellation: Stripe Dashboard → Customers → cancel the subscription →
   the organisation drops back to `pending` (locked out — there is no free tier)

## 8. Add the Stripe secret key to Supabase

`super-stripewebhooks`, `create-portal-session`, `delete-account`, and
`set-seat-count` all call Stripe's API (not just verify inbound events), so
they need your actual secret key.

Supabase Dashboard → **Edge Functions** → **Secrets** → add
`STRIPE_SECRET_KEY` = your Stripe **secret key** (`sk_test_...` in test mode).
**Never** commit this key anywhere in the repo — it belongs only in this secret.
It's shared across every Edge Function in the project, so this is a one-time step.

## 9. Deploy the account/billing-management functions

Five functions besides the webhook: `create-portal-session` (Manage
subscription), `delete-account`, `create-team-member`/`update-team-member`
(owner-provisioned logins — no billing involved), **`kick-user`** (the admin
console's "Log out" on an active session — frees a concurrent seat), and
**`set-seat-count`** (only used on the multi-venue tier, when the owner changes
how many extra concurrent seats they're paying for — see the org-model planning
doc for why this needs to be server-side at all).

**Every one of these must actually be deployed.** A function that exists in the
repo but was never deployed fails in the app as
*"Failed to send a request to the Edge Function"* — that's supabase-js unable to
**reach** the function (404), not the function rejecting the request, so it
looks like a client bug rather than a missing deploy. If you see that message,
check this list first.

**Important — opposite of the webhook**: leave **"Enforce JWT verification" ON**
for all of these. They act on behalf of whoever calls them, using that
caller's own Supabase session to identify them.

```sh
supabase functions deploy create-portal-session --project-ref vfixdchbkmqryfhirphx
supabase functions deploy delete-account --project-ref vfixdchbkmqryfhirphx
supabase functions deploy create-team-member --project-ref vfixdchbkmqryfhirphx
supabase functions deploy update-team-member --project-ref vfixdchbkmqryfhirphx
supabase functions deploy kick-user --project-ref vfixdchbkmqryfhirphx
supabase functions deploy set-seat-count --project-ref vfixdchbkmqryfhirphx
```

(Omit `--no-verify-jwt` — that flag is specific to the webhook.) If deploying via
the dashboard editor instead, just don't touch the JWT verification toggle; it
defaults to on.

## 10. Turn on self-service cancellation (Stripe Customer Portal)

The app's Account view has a **Manage subscription** button (owner-only) that
opens Stripe's hosted Customer Portal.

1. Stripe Dashboard → **Settings** → **Billing** → **Customer portal**
2. Under **Subscriptions**, make sure **Customers can cancel subscriptions** is
   turned on (it's on by default in test mode, but double-check)
3. Save. No link to copy — the app requests a portal session per-organisation via
   `create-portal-session`.

## 11. Test everything else

**Manage subscription**: sign in as the organisation **owner** of a paid org →
👤 Account → **Manage subscription** → confirm it opens the Stripe portal for
the right customer, and that a staff/manager account gets a clear "only the
owner can manage billing" error instead (403).

**Multi-venue location add/remove**: as owner/manager of a multi-venue org, add
a location in `admin.html` → confirm the Stripe subscription's quantity
increments; remove one → confirm it decrements. Try removing a location that
still has stocktakes — should be blocked with a clear message, not a raw
database error.

**Delete account** — three cases, all worth testing with throwaway accounts:
- **Solo org** (you're the only member): delete → confirm the Stripe
  subscription (if any) is cancelled, the organisation and all its
  locations/stocktakes are gone (Supabase Table Editor), and the user is gone
  (Authentication → Users).
- **Sole owner with staff still in the org**: delete → should be **blocked**
  with a message asking you to promote a co-owner or remove the other members
  first — nothing should actually be deleted.
- **Staff/manager leaving an org that has other members**: delete → the user
  is gone, but the organisation, its locations, and its stocktakes are
  untouched (only that person's own `created_by`/`scanned_by` attribution on
  old rows goes null, per schema.sql).

## Notes

- **Never** put the `sk_...` secret key in this repo or the website. Only Payment
  Link URLs (safe) and the publishable `pk_...` key (also safe, and currently not
  even needed) may appear in frontend code. `STRIPE_SECRET_KEY` lives only in
  Supabase's Edge Function secrets (§8) — it is never sent to the browser.
- **Native apps** (see `NATIVE-SETUP.md`): the redirect URL above doesn't need to
  change. On iOS/Android the checkout opens in an in-app browser tab, so that
  `?upgraded=1` page loads there rather than in the app's own screen — the app
  instead re-checks the org's plan when it resumes from the foreground (i.e.
  right after the user closes the checkout tab), not from the `upgraded=1` toast.
- If a payment ever arrives without an account match (shouldn't happen via the
  app, but possible if someone pays a raw link directly), the webhook logs it;
  you can activate manually with the SQL at the bottom of `schema.sql`.
- Going live later: create the same products/prices/links in live mode, a live
  webhook endpoint + secret, and swap `config.js` URLs and the Supabase secrets.
