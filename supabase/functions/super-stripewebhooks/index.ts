// Gantry Stripe webhook — runs as a Supabase Edge Function.
//
// Flips organisations.plan_tier when Stripe reports a completed checkout,
// a cancelled subscription, or a tier change. There's no free plan — a
// cancelled subscription drops the org back to 'pending' (the same locked-
// out state a brand-new, never-paid org starts in; see schema.sql), not
// some lesser usable tier. checkout.session.completed also creates the
// org's first venue and its first location if they don't exist yet, since
// that no longer happens at signup (create_organisation() in schema.sql) —
// the org isn't usable at all until payment completes. Deploy instructions:
// STRIPE-SETUP.md.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_WEBHOOK_SECRET  - the "whsec_..." signing secret of the webhook endpoint
//   STRIPE_SECRET_KEY      - the "sk_..." secret key (already added for
//                            create-portal-session/delete-account — Supabase
//                            secrets are project-wide, so it's already
//                            available here too, no new secret to add)
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
//
// OPTIONAL: RESEND_API_KEY (or POSTMARK_SERVER_TOKEN) + MAIL_FROM enable the
// "thanks for upgrading" email — see _shared/email.ts and EMAIL-SETUP.md.
// Without them the checkout still completes exactly as before and the send is
// skipped with a log line; email is never allowed to fail this webhook.

import { mailFooter, sendEmail } from "../_shared/email.ts";

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

// Maps a Stripe Price id to which plan_tier it represents. Doesn't need to
// know about billing period at all — monthly and annual are just two
// different prices mapping to the same tier, Stripe handles the amount/
// interval on its own. Update this (and redeploy) every time a new
// single/multi-venue Payment Link is created in the Stripe Dashboard — see
// STRIPE-SETUP.md's Phase D section. PLACEHOLDER: fill in the real price
// ids once the products/prices exist.
const PRICE_TIER_MAP: Record<string, "single" | "multi"> = {
  // Reused from the pre-org-tier "Barscan Pro" product (renamed to "Barscan
  // Single-venue" — same price ids, nothing about the price itself changed.
  // Still named "Barscan..." in the live Stripe Dashboard as of the Gantry
  // rebrand — see STRIPE-SETUP.md's note on renaming the live products).
  "price_1TvX8tEiJERMRN7vG2cavZde": "single", // EUR annual  ($270/yr)
  "price_1TvVCKEiJERMRN7vJzOdO9Qp": "single", // EUR monthly ($27/mo)
  "price_1TvVC4EiJERMRN7vKoqap7Mj": "single", // GBP annual  (£250/yr)
  "price_1TvVAvEiJERMRN7vV0ndm2c0": "single", // GBP monthly (£25/mo)
  "price_1TvVAFEiJERMRN7vnJ3vq2l1": "single", // USD annual  ($270/yr)
  "price_1TvVA0EiJERMRN7vD4QpJ4pz": "single", // USD monthly ($27/mo)
  "price_1Tv5fIEiJERMRN7vAfgFfbca": "single", // AUD annual  (A$290/yr)
  "price_1Tv5ejEiJERMRN7vvAweNVYU": "single", // AUD monthly (A$29/mo)

  "price_1TzmL3EiJERMRN7vOlaRkmPS": "multi", // AUD monthly (A$59/mo base)
  "price_1U0UYUEiJERMRN7vdmuqpNi6": "multi", // AUD annual  (A$590/yr base)
  // AUD-only for now (per dev decision — see the org-model planning doc /
  // this session's history) — USD/GBP/EUR Multi-venue prices not created.
  // Every non-AUD country already falls back to AUD's real links/prices
  // (upgradeLink()/renderUpgradePrices() in app.html, DEFAULT_CURRENCY),
  // so this isn't a gap, just a deliberately deferred currency.
  // "price_XXXXXXXXXXXXXX_AUD_MULTI_ANNUAL":  "multi",
  // ...8 more once Multi-venue's prices exist (one per currency per period)
};

const encoder = new TextEncoder();

const APP_URL = "https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html";

// Says thank you, names what they just bought, and points at the two things
// they will look for next (getting started, and where billing lives).
//
// Deliberately OUR email rather than relying on Stripe's receipt: the receipt
// is a tax document and says nothing about the product. This is also the only
// message that explains the one thing about Multi-venue people get wrong —
// unlimited logins, paid concurrency — at the moment they have just paid for it.
//
// Fire-and-forget, exactly like notify-seat-denied: sendEmail() returns
// { sent: false } instead of throwing when no provider secret is configured, so
// this ships and does nothing until RESEND_API_KEY exists. It must never be
// able to fail the webhook — Stripe retries a non-2xx, and retrying a payment
// event because an email bounced would re-run the whole handler.
async function sendUpgradeWelcome(tier: "single" | "multi", to: string | undefined, orgId: string) {
  if (!to) {
    console.log("upgrade welcome: no customer email on the session, skipping");
    return;
  }
  const planLabel = tier === "multi" ? "Multi-venue" : "Single-venue";
  // The ORGANISATION's name, not session.customer_details.name — the latter is
  // whoever's card it was, and "Alex Taylor is now on Multi-venue" is not what
  // the person who just bought a venue subscription expects to read. Best
  // effort: a failed lookup falls back to "you're", never to a blank.
  let orgName: string | undefined;
  try {
    const res = await db(`organisations?id=eq.${encodeURIComponent(orgId)}&select=name`);
    if (res.ok) orgName = (await res.json())[0]?.name;
  } catch (_) { /* name is a nicety; the email still goes without it */ }
  const lines = [
    `Thanks — ${orgName ? orgName + " is" : "you're"} now on Gantry ${planLabel}.`,
    "",
    tier === "multi"
      ? [
        "What you've got:",
        "  · Unlimited venues and locations",
        "  · Unlimited products in every stocktake",
        "  · As many people set up as you like, at no charge per person",
        "",
        "One thing worth knowing: you pay for how many people can be COUNTING",
        "AT THE SAME TIME, not for how many logins you create. Set everyone up.",
        "Change how many can count at once any time from the admin console.",
      ].join("\n")
      : [
        "What you've got:",
        "  · Unlimited products in every stocktake",
        "  · Unlimited stocktakes, and CSV export whenever you need it",
        "",
        "Single-venue covers one venue and one user — you. If you need staff",
        "counting too, Multi-venue adds that; upgrade any time from Account.",
      ].join("\n"),
    "",
    "Pick up where you left off:",
    "  " + APP_URL,
    "",
    "Your invoices, card details and cancellation all live in the billing",
    "portal — open it from Account in the app.",
  ].join("\n");

  const result = await sendEmail({
    to,
    subject: `You're on Gantry ${planLabel}`,
    text: lines + mailFooter(),
  });
  if (!result.sent) console.log("upgrade welcome not sent:", result.provider, result.error ?? "");
}

async function verifyStripeSignature(payload: string, header: string): Promise<boolean> {
  // Stripe-Signature: t=<timestamp>,v1=<hmac>,...
  const parts = Object.fromEntries(
    header.split(",").map((kv) => kv.split("=") as [string, string]),
  );
  const timestamp = parts["t"];
  const expected = parts["v1"];
  if (!timestamp || !expected) return false;
  // Reject events older than 5 minutes to limit replay
  if (Math.abs(Date.now() / 1000 - Number(timestamp)) > 300) return false;

  const key = await crypto.subtle.importKey(
    "raw", encoder.encode(WEBHOOK_SECRET),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, encoder.encode(`${timestamp}.${payload}`));
  const hex = Array.from(new Uint8Array(sig)).map((b) => b.toString(16).padStart(2, "0")).join("");
  if (hex.length !== expected.length) return false;
  let diff = 0;
  for (let i = 0; i < hex.length; i++) diff |= hex.charCodeAt(i) ^ expected.charCodeAt(i);
  return diff === 0;
}

// `init: RequestInit = {}`, and the default is not cosmetic. Two callers in
// ensureFirstVenue() invoke this with only a path, and without the default `init`
// is undefined — so `init.headers` below threw
// "Cannot read properties of undefined (reading 'headers')" on the FIRST line of
// ensureFirstVenue, on every single checkout.
//
// The failure was quiet in the worst way: setOrgPlan() runs before this and
// succeeded, so checkout appeared to work and plan_tier flipped correctly — but
// the org's first venue and location were never created, and Stripe saw a 500
// and retried the webhook indefinitely. The visible symptom was an operator
// unable to add their first location, because there was no venue to attach it
// to. (app.html's Team view now self-heals that, but this was the actual cause.)
//
// Every other Edge Function in this project already declares its db() helper with
// `= {}`; this one was the outlier. Found by `deno check` — see
// .claude/skills/verify/SKILL.md for how to run it.
async function db(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      Prefer: "return=minimal",
      ...(init.headers ?? {}),
    },
  });
}

async function stripeGetJson(path: string): Promise<any> {
  const res = await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
  });
  if (!res.ok) throw new Error(`Stripe GET ${path} failed: ${res.status} ${await res.text()}`);
  return res.json();
}

async function setOrgPlan(
  orgId: string,
  tier: string,
  extra?: { customerId?: string; subscriptionId?: string; subscriptionItemId?: string },
) {
  const body: Record<string, unknown> = { plan_tier: tier };
  if (extra?.customerId) body.stripe_customer_id = extra.customerId;
  if (extra?.subscriptionId) body.stripe_subscription_id = extra.subscriptionId;
  if (extra?.subscriptionItemId) body.stripe_subscription_item_id = extra.subscriptionItemId;
  const res = await db(`organisations?id=eq.${encodeURIComponent(orgId)}`, {
    method: "PATCH",
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`organisations update failed: ${res.status} ${await res.text()}`);
}

async function setPlanByCustomer(customerId: string, tier: string) {
  const res = await db(`organisations?stripe_customer_id=eq.${encodeURIComponent(customerId)}`, {
    method: "PATCH",
    body: JSON.stringify({ plan_tier: tier }),
  });
  if (!res.ok) throw new Error(`organisations update failed: ${res.status} ${await res.text()}`);
}

// Ensures the org has at least one venue, returning its id — creates one
// ("Main") if it doesn't, a no-op returning the existing one for a
// tier-change checkout on an org that already has a venue (e.g. single ->
// multi via a fresh checkout rather than the portal). The create path also
// writes an explicit audit_log row: the venues audit trigger (schema.sql)
// no-ops for this insert since it runs under the service role with no
// end-user JWT (auth.uid() is null there), so this is the only place that
// ever logs it — same reasoning as every other service-role write here.
async function ensureFirstVenue(orgId: string): Promise<string> {
  const existingRes = await db(`venues?org_id=eq.${encodeURIComponent(orgId)}&select=id&order=created_at&limit=1`);
  const existing = await existingRes.json();
  if (existing.length > 0) return existing[0].id;

  const res = await db(`venues`, {
    method: "POST",
    headers: { Prefer: "return=representation" },
    body: JSON.stringify({ org_id: orgId, name: "Main" }),
  });
  if (!res.ok) throw new Error(`venue create failed: ${res.status} ${await res.text()}`);
  const [venue] = await res.json();

  const orgRes = await db(`organisations?id=eq.${encodeURIComponent(orgId)}&select=name`);
  const [org] = await orgRes.json();

  await db(`audit_log`, {
    method: "POST",
    body: JSON.stringify({
      org_id: orgId, org_label: org?.name ?? "Unknown organisation", actor_id: null,
      actor_label: "Stripe checkout", action: "venue.created", entity_type: "venue",
      entity_id: venue.id, target_label: venue.name, after: venue,
    }),
  });
  return venue.id;
}

// Creates the given venue's first location if it doesn't have one yet —
// same no-op-if-exists shape as ensureFirstVenue() above, one level down.
async function ensureFirstLocation(orgId: string, venueId: string) {
  const countRes = await db(`locations?venue_id=eq.${encodeURIComponent(venueId)}&select=id`, {
    headers: { Prefer: "count=exact" },
  });
  const contentRange = countRes.headers.get("content-range") ?? "";
  const existingCount = Number(contentRange.split("/")[1]) || (await countRes.json()).length;
  if (existingCount > 0) return;

  const res = await db(`locations`, {
    method: "POST",
    body: JSON.stringify({ org_id: orgId, venue_id: venueId, name: "Main" }),
  });
  if (!res.ok) throw new Error(`location create failed: ${res.status} ${await res.text()}`);
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const signature = req.headers.get("stripe-signature") ?? "";
  const payload = await req.text();
  if (!WEBHOOK_SECRET || !(await verifyStripeSignature(payload, signature))) {
    return new Response("invalid signature", { status: 400 });
  }

  const event = JSON.parse(payload);
  try {
    switch (event.type) {
      case "checkout.session.completed": {
        const session = event.data.object;
        // The app appends ?client_reference_id=<organisation id> to the
        // Payment Link (billing is org-scoped, not per-user) — this is how
        // the webhook knows which org just paid.
        const orgId = session.client_reference_id;
        const customerId = typeof session.customer === "string" ? session.customer : undefined;
        const subscriptionId = typeof session.subscription === "string" ? session.subscription : undefined;
        if (!orgId) {
          console.error("checkout.session.completed without client_reference_id", session.id);
          break;
        }
        if (!subscriptionId) {
          console.error("checkout.session.completed without a subscription", session.id);
          break;
        }
        // One Stripe call gets both the purchased price (-> tier) and the
        // subscription item id (needed later by set-seat-count to keep
        // quantity in sync with purchased concurrent-seat count).
        const sub = await stripeGetJson(`subscriptions/${subscriptionId}`);
        const priceId = sub.items?.data?.[0]?.price?.id;
        const subscriptionItemId = sub.items?.data?.[0]?.id;
        const tier = priceId ? PRICE_TIER_MAP[priceId] : undefined;
        if (!tier) {
          console.error("checkout.session.completed with unrecognized price", priceId, session.id);
          break;
        }
        await setOrgPlan(orgId, tier, { customerId, subscriptionId, subscriptionItemId });
        const venueId = await ensureFirstVenue(orgId);
        await ensureFirstLocation(orgId, venueId);
        // Last, and wrapped: everything above changes state that the customer
        // has paid for, and none of it may be undone or retried because a mail
        // provider had a bad minute. Stripe retries any non-2xx response, so a
        // throw here would re-run the entire handler.
        try {
          await sendUpgradeWelcome(tier, session.customer_details?.email, orgId);
        } catch (mailErr) {
          console.error("upgrade welcome threw (ignored):", mailErr);
        }
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object;
        const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer?.id;
        // Locked out, same as a never-paid org — not deleted, just
        // inaccessible until they resubscribe (see setPlanByCustomer's
        // caller comment / the header comment above).
        if (customerId) await setPlanByCustomer(customerId, "pending");
        break;
      }
      case "customer.subscription.updated": {
        // Tier changed on an existing subscription (e.g. you switch someone
        // between single/multi-venue prices directly in Stripe) — re-derive
        // the tier from the subscription's current price and keep
        // organisations.plan_tier in sync.
        const sub = event.data.object;
        const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer?.id;
        const priceId = sub.items?.data?.[0]?.price?.id;
        const tier = priceId ? PRICE_TIER_MAP[priceId] : undefined;
        if (customerId && tier) await setPlanByCustomer(customerId, tier);
        break;
      }
      default:
        break; // ignore other events
    }
    return new Response(JSON.stringify({ received: true }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("webhook handling failed:", err);
    return new Response("handler error", { status: 500 });
  }
});
