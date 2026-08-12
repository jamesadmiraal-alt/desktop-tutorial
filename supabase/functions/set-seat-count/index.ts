// Barscan multi-venue concurrent-seat billing — runs as a Supabase Edge Function.
//
// Owner-only, multi-venue-tier-only. Lets the owner set how many
// CONCURRENT seats they're paying for beyond themselves (they're always
// free — see claim_seat() in schema.sql). Venues/locations carry no
// billing consequence any more; this is the only billable knob left for
// the multi-venue tier.
//
// Unlike create-location/remove-location's recent refactor (where
// service role turned out to be unnecessary because RLS already
// permitted the write), this one DOES need service role for its final
// write: organisations.concurrent_seats is deliberately NOT in the
// client-writable column GRANT (schema.sql) — same protected treatment
// as plan_tier/stripe_customer_id, since it's a billing number tied to a
// real Stripe charge, not a preference an owner should be able to set
// directly. The owner-role check itself still runs under the caller's
// own JWT; only the final write to concurrent_seats uses the service role,
// and only after the matching Stripe PATCH has already succeeded.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (already added for the
//                        other billing functions — shared project-wide)
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

// Forwarded caller JWT — used for the owner/plan-tier check, so that
// check runs under real RLS rather than the service role bypassing it.
async function userDb(authHeader: string, path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: ANON_KEY,
      Authorization: authHeader,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

// Service role — only for the final organisations.concurrent_seats
// write, which RLS deliberately does not allow directly (see header
// comment above).
async function db(path: string, init: RequestInit = {}): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
      ...(init.headers ?? {}),
    },
  });
}

async function stripePatch(path: string, params: Record<string, string>): Promise<Response> {
  return await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST", // Stripe's API uses POST for updates too, not PATCH
    headers: {
      Authorization: `Bearer ${STRIPE_SECRET_KEY}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams(params),
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: CORS_HEADERS });

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Not signed in" }, 401);

  let seats = -1;
  try {
    const body = await req.json();
    seats = Number(body?.seats);
  } catch {
    // no/invalid body — seats stays -1, caught below
  }
  if (!Number.isInteger(seats) || seats < 0) return jsonResponse({ error: "seats must be a non-negative whole number." }, 400);

  try {
    const memberRes = await userDb(
      authHeader,
      `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(id,plan_tier,stripe_subscription_item_id)`,
    );
    const members = await memberRes.json();
    const membership = members?.[0];
    if (!membership || membership.role !== "owner") {
      return jsonResponse({ error: "Only the owner can change the seat count." }, 403);
    }
    const org = membership.organisations;
    if (org.plan_tier !== "multi") {
      return jsonResponse({ error: "Concurrent seats only apply to the multi-venue plan." }, 400);
    }
    if (!org.stripe_subscription_item_id) {
      return jsonResponse({ error: "This organisation's billing isn't fully set up yet." }, 400);
    }

    // +1 for the base tier slot (up to 1 unit = the $59 flat fee covering
    // the owner) — same graduated-pricing arithmetic the old location
    // quantity sync used, just repointed at seats instead of locations.
    const stripeRes = await stripePatch(`subscription_items/${org.stripe_subscription_item_id}`, {
      quantity: String(1 + seats),
    });
    if (!stripeRes.ok) {
      throw new Error(`Stripe quantity update failed: ${stripeRes.status} ${await stripeRes.text()}`);
    }

    const updateRes = await db(`organisations?id=eq.${encodeURIComponent(org.id)}`, {
      method: "PATCH",
      body: JSON.stringify({ concurrent_seats: seats }),
    });
    if (!updateRes.ok) {
      // Stripe already charged the new quantity but our own record didn't
      // save — surface plainly rather than silently drifting out of sync.
      throw new Error(`concurrent_seats update failed: ${updateRes.status} ${await updateRes.text()}`);
    }

    return jsonResponse({ concurrentSeats: seats });
  } catch (err) {
    console.error("set-seat-count failed:", err);
    return jsonResponse({ error: "Could not update seat count" }, 500);
  }
});
