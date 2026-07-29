// Barscan multi-venue location creation — runs as a Supabase Edge Function.
//
// Only needed for the multi-venue tier: adding a location beyond an org's
// first has to increment that org's Stripe subscription quantity, which a
// plain Postgres RLS-gated insert can't do. admin.html calls this instead
// of a direct client insert specifically when currentOrg.planTier ===
// 'multi' — free/single tier (always adding their first-and-only location)
// keeps using the plain insert, unaffected by this function.
//
// Identifies the caller from their own Supabase session (JWT verification
// ON, same as create-portal-session/delete-account — see STRIPE-SETUP.md).
// Owner/manager only.
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

  let name = "";
  try {
    const body = await req.json();
    name = String(body?.name ?? "").trim();
  } catch {
    // no/invalid body — name stays empty, caught below
  }
  if (!name) return jsonResponse({ error: "Location name is required." }, 400);

  try {
    const memberRes = await db(
      `memberships?user_id=eq.${encodeURIComponent(user.id)}` +
        `&select=role,organisations(id,plan_tier,stripe_subscription_item_id)`,
    );
    const members = await memberRes.json();
    const membership = members?.[0];
    if (!membership || (membership.role !== "owner" && membership.role !== "manager")) {
      return jsonResponse({ error: "Only owners and managers can add locations." }, 403);
    }
    const org = membership.organisations;
    if (org.plan_tier !== "multi") {
      return jsonResponse({ error: "Upgrade to the multi-venue plan to add more locations." }, 400);
    }
    if (!org.stripe_subscription_item_id) {
      return jsonResponse({ error: "This organisation's billing isn't fully set up yet." }, 400);
    }

    const insertRes = await db(`locations`, {
      method: "POST",
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ org_id: org.id, name }),
    });
    if (!insertRes.ok) {
      const detail = await insertRes.text();
      // Most likely a duplicate name (unique(org_id, name)) — surface it plainly.
      return jsonResponse({ error: /duplicate key/i.test(detail) ? "A location with that name already exists." : "Could not create location." }, 400);
    }
    const inserted = (await insertRes.json())[0];

    // Recount rather than increment — self-correcting instead of
    // accumulating drift if a previous sync ever failed partway.
    const countRes = await db(`locations?org_id=eq.${encodeURIComponent(org.id)}&select=id`, {
      headers: { Prefer: "count=exact" },
    });
    const contentRange = countRes.headers.get("content-range") ?? "";
    const quantity = Number(contentRange.split("/")[1]) || (await countRes.json()).length;

    const stripeRes = await stripePatch(`subscription_items/${org.stripe_subscription_item_id}`, {
      quantity: String(quantity),
    });
    if (!stripeRes.ok) {
      // Roll back — don't leave the location count and Stripe quantity out of sync.
      await db(`locations?id=eq.${encodeURIComponent(inserted.id)}`, { method: "DELETE" });
      throw new Error(`Stripe quantity update failed: ${stripeRes.status} ${await stripeRes.text()}`);
    }

    return jsonResponse({ location: inserted });
  } catch (err) {
    console.error("create-location failed:", err);
    return jsonResponse({ error: "Could not create location" }, 500);
  }
});
