// Barscan Stripe webhook — runs as a Supabase Edge Function.
//
// Flips organisations.plan_tier when Stripe reports a completed checkout,
// a cancelled subscription, or a tier change — and off again to 'free' on
// cancellation. Deploy instructions: STRIPE-SETUP.md.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_WEBHOOK_SECRET  - the "whsec_..." signing secret of the webhook endpoint
//   STRIPE_SECRET_KEY      - the "sk_..." secret key (already added for
//                            create-portal-session/delete-account — Supabase
//                            secrets are project-wide, so it's already
//                            available here too, no new secret to add)
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

// Maps a Stripe Price id to which plan_tier it represents. Update this (and
// redeploy) every time a new single/multi-venue Payment Link is created in
// the Stripe Dashboard — see STRIPE-SETUP.md's Phase D section. PLACEHOLDER:
// fill in the real price ids once the products/prices exist.
const PRICE_TIER_MAP: Record<string, "single" | "multi"> = {
  // "price_XXXXXXXXXXXXXX_AUD_SINGLE": "single",
  // "price_XXXXXXXXXXXXXX_AUD_MULTI":  "multi",
  // ...one entry per currency per tier (8 total)
};

const encoder = new TextEncoder();

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

async function db(path: string, init: RequestInit): Promise<Response> {
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
        // subscription item id (needed later by create-location/
        // remove-location to keep quantity in sync with location count).
        const sub = await stripeGetJson(`subscriptions/${subscriptionId}`);
        const priceId = sub.items?.data?.[0]?.price?.id;
        const subscriptionItemId = sub.items?.data?.[0]?.id;
        const tier = priceId ? PRICE_TIER_MAP[priceId] : undefined;
        if (!tier) {
          console.error("checkout.session.completed with unrecognized price", priceId, session.id);
          break;
        }
        await setOrgPlan(orgId, tier, { customerId, subscriptionId, subscriptionItemId });
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object;
        const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer?.id;
        if (customerId) await setPlanByCustomer(customerId, "free");
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
