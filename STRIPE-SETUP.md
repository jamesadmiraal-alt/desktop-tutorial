# Connecting Stripe to Barscan (test mode)

Barscan uses **Stripe Payment Links** for checkout and a **Supabase Edge Function**
webhook to activate Pro automatically after payment. No server of your own is needed.

Everything below happens in the Stripe **sandbox/test** dashboard first. When you go
live, repeat the same steps in live mode and swap the URLs/secrets.

## 1. Create the product and prices (Stripe Dashboard)

1. Stripe Dashboard → **Product catalog** → **+ Add product**
2. Name: `Barscan Pro` · Description: `Unlimited products per stocktake`
3. Add **two recurring prices**:
   - `$29.00` / **month**
   - `$290.00` / **year**  *(the "2 months free" annual deal)*

## 2. Create two Payment Links

For **each** of the two prices: **Payment links** → **+ New** → pick the price, then
under **After payment** choose **Don't show confirmation page** and set the redirect URL to:

```
https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html?upgraded=1
```

Copy both link URLs (they look like `https://buy.stripe.com/test_...`).

## 3. Put the links into the app

In `config.js`:

```js
upgradeUrl:       'https://buy.stripe.com/test_XXXX',  // $29/month link
upgradeUrlAnnual: 'https://buy.stripe.com/test_YYYY',  // $290/year link
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

## Notes

- **Never** put the `sk_...` secret key in this repo or the website. Only Payment
  Link URLs (safe) and the publishable `pk_...` key (also safe, and currently not
  even needed) may appear in frontend code.
- If a payment ever arrives without an account match (shouldn't happen via the app,
  but possible if someone pays the raw link), the webhook logs it; you can activate
  manually with the SQL at the bottom of `schema.sql`.
- Going live later: create the same product/prices/links in live mode, a live
  webhook endpoint + secret, and swap `config.js` URLs and the Supabase secret.
