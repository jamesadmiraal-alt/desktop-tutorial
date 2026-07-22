# Connecting Stripe to Barscan (test mode)

Barscan uses **Stripe Payment Links** for checkout and a **Supabase Edge Function**
webhook to activate Pro automatically after payment. No server of your own is needed.

Everything below happens in the Stripe **sandbox/test** dashboard first. When you go
live, repeat the same steps in live mode and swap the URLs/secrets.

## 1. Create the product and prices (Stripe Dashboard)

Barscan picks a Stripe Payment Link based on the operator's country (set at signup,
editable in 👤 Account) — see `COUNTRY_CURRENCY` in `app.html`. Today that maps to four
currencies: **AUD** (default/home currency — Australia), **USD** (US), **GBP** (UK),
**EUR** (Ireland/Germany/France/Spain/Italy/Netherlands). AUD is already set up
(`$29.00`/month, `$290.00`/year on the existing `Barscan Pro` product) — the app falls
back to the AUD link for any currency you haven't configured yet, so it's safe to add
the others one at a time.

1. Stripe Dashboard → **Product catalog** → open the existing **Barscan Pro** product
2. Click **+ Add another price** and add **two recurring prices per new currency**
   (Stripe lets one product hold prices in multiple currencies) — pick whatever amounts
   make sense for that market, they don't have to be an exact conversion:
   - **USD**: `$29.00`/month, `$290.00`/year *(or your own USD pricing)*
   - **GBP**: `£25.00`/month, `£250.00`/year
   - **EUR**: `€27.00`/month, `€270.00`/year

## 2. Create a Payment Link per new price

For **each** new price (USD/GBP/EUR × monthly/annual — 6 in total):
**Payment links** → **+ New** → pick the price, then under **After payment** choose
**Don't show confirmation page** and set the redirect URL to:

```
https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html?upgraded=1
```

This redirect URL is the same for every currency/plan (and matches the existing AUD
links) — copy each resulting link (`https://buy.stripe.com/test_...`).

## 3. Put the links into the app

In `config.js`'s `upgradeUrls`, keyed by currency (leave a currency's `monthly`/`annual`
as `''` until you've created that currency's links — the app falls back to AUD, the
already-configured default):

```js
upgradeUrls: {
  AUD: { monthly: 'https://buy.stripe.com/test_fZu14n...', annual: 'https://buy.stripe.com/test_cNi3c...' }, // already set
  USD: { monthly: 'PASTE HERE', annual: 'PASTE HERE' },
  GBP: { monthly: 'PASTE HERE', annual: 'PASTE HERE' },
  EUR: { monthly: 'PASTE HERE', annual: 'PASTE HERE' }
}
```

The app automatically appends `client_reference_id` (the Supabase user id) and
`prefilled_email` to these links, which is how the webhook knows whose account to upgrade.

## 4. Deploy the webhook (Supabase)

The function lives at `supabase/functions/stripe-webhook/index.ts`.

**Easiest — dashboard editor:** Supabase Dashboard → **Edge Functions** → **Deploy a new
function** → via editor → name it `stripe-webhook`, paste the file's contents, deploy.
Then under the function's settings **disable "Enforce JWT verification"** (Stripe calls
it unauthenticated; it verifies its own signature instead).

**Or via CLI:**

```sh
supabase functions deploy stripe-webhook --no-verify-jwt --project-ref vfixdchbkmqryfhirphx
```

The function's URL will be:

```
https://vfixdchbkmqryfhirphx.supabase.co/functions/v1/stripe-webhook
```

## 5. Point Stripe at the webhook

1. Stripe Dashboard → **Developers** → **Webhooks** → **+ Add endpoint**
2. Endpoint URL: the function URL above
3. Events to send: `checkout.session.completed` and `customer.subscription.deleted`
4. After creating it, copy the **Signing secret** (`whsec_...`)
5. Supabase Dashboard → **Edge Functions** → **Secrets** → add
   `STRIPE_WEBHOOK_SECRET` = that `whsec_...` value

## 6. Test the whole flow

1. In the app, sign in with a **free** account and tap 👤 → **Pro Monthly**
2. On the Stripe test checkout, pay with card `4242 4242 4242 4242`, any future
   expiry, any CVC
3. You're redirected back to the app with a "Payment received" message
4. Within a few seconds the webhook flips your account to Pro — open 👤 Account
   and the green **Pro plan** badge should appear; a 4th product now scans fine
5. To test cancellation: Stripe Dashboard → Customers → cancel the subscription →
   the account drops back to Free

## 7. Turn on self-service cancellation (Stripe Customer Portal)

The app's Account view has a **Manage subscription** button that opens Stripe's
hosted Customer Portal, where operators can update their payment method, view
invoices, or cancel — without emailing you.

1. Stripe Dashboard → **Settings** → **Billing** → **Customer portal**
2. Under **Subscriptions**, make sure **Customers can cancel subscriptions** is
   turned on (it's on by default in test mode, but double-check — this is what
   makes cancellation actually self-service instead of just informational)
3. Save. No link to copy here — the app requests a portal session per-user via
   the `create-portal-session` edge function below.

## 8. Add the Stripe secret key to Supabase

Unlike the webhook (which only *verifies* incoming Stripe events), the two new
functions below *call* Stripe's API — creating a portal session, cancelling a
subscription — so they need your actual secret key, not just the webhook secret.

Supabase Dashboard → **Edge Functions** → **Secrets** → add
`STRIPE_SECRET_KEY` = your Stripe **secret key** (`sk_test_...` in test mode).
**Never** commit this key anywhere in the repo — it belongs only in this secret.

## 9. Deploy the account-management functions

Two new functions: `supabase/functions/create-portal-session` (Manage
subscription) and `supabase/functions/delete-account` (Delete account).

**Important — opposite of the webhook**: leave **"Enforce JWT verification" ON**
for both of these. They act on behalf of whoever calls them, using that
caller's own Supabase session to identify them — unlike the webhook, which
Stripe calls unauthenticated and which verifies itself via signature instead.

```sh
supabase functions deploy create-portal-session --project-ref vfixdchbkmqryfhirphx
supabase functions deploy delete-account --project-ref vfixdchbkmqryfhirphx
```

(Omit `--no-verify-jwt` — that flag is specific to the webhook.) If deploying via
the dashboard editor instead, just don't touch the JWT verification toggle; it
defaults to on.

## 10. Test both flows

**Manage subscription**: sign in as a Pro user → 👤 Account → **Manage
subscription** → confirm it opens the Stripe portal for the right customer,
that cancelling there actually cancels (not just "scheduled" with no way to
confirm), and that returning to the app eventually shows Free once the
subscription period ends (the existing webhook's `customer.subscription.deleted`
handling covers that automatically — no changes needed there).

**Delete account**: sign in as a **test** user with an active subscription →
👤 Account → **Delete account** → confirm → check in Stripe that the
subscription was cancelled immediately (not left running), and in Supabase
**Authentication → Users** that the user is gone (and that their `stocktakes`/
`stocktake_items` rows are gone too, via the cascade deletes in `schema.sql`).

## Notes

- **Never** put the `sk_...` secret key in this repo or the website. Only Payment
  Link URLs (safe) and the publishable `pk_...` key (also safe, and currently not
  even needed) may appear in frontend code. The new `STRIPE_SECRET_KEY` used by
  `create-portal-session`/`delete-account` lives only in Supabase's Edge Function
  secrets (§8) — it is never sent to the browser.
- **Native apps** (see `NATIVE-SETUP.md`): the redirect URL above doesn't need to
  change. On iOS/Android the checkout opens in an in-app browser tab, so that
  `?upgraded=1` page loads there rather than in the app's own screen — the app
  instead re-checks `is_pro` when it resumes from the foreground (i.e. right after
  the user closes the checkout tab), not from the `upgraded=1` toast.
- If a payment ever arrives without an account match (shouldn't happen via the app,
  but possible if someone pays the raw link), the webhook logs it; you can activate
  manually with the SQL at the bottom of `schema.sql`.
- Going live later: create the same product/prices/links in live mode, a live
  webhook endpoint + secret, and swap `config.js` URLs and the Supabase secret.
