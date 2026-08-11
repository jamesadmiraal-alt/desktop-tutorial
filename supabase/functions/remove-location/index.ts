// Barscan multi-venue location removal — runs as a Supabase Edge Function.
//
// The counterpart to create-location: removing a location on the
// multi-venue tier has to decrement that org's Stripe subscription
// quantity, which a plain RLS-gated delete can't do. admin.html's remove
// button (only ever shown when an org has more than one location, which is
// only possible on the multi-venue tier) calls this instead.
//
// Identifies the caller from their own Supabase session (JWT verification
// ON — see STRIPE-SETUP.md). Owner/manager only. Doesn't need special
// handling for "can't remove a location that still has stocktakes" — the
// `location_id ... on delete restrict` FK (schema.sql) already blocks that
// at the database level; this just surfaces that error legibly.
//
// The Postgres-side work (membership/org lookup, the actual locations
// delete, the recount) runs as the CALLER's own session, not the service
// role — RLS already permits everything this function does to `locations`
// under an owner/manager's own session (see the "owner manager delete
// locations"/"owner manager insert locations" policies in schema.sql), so
// service-role was never required there, only for the Stripe call below.
// Running it as the caller means schema.sql's log_locations_change()
// trigger picks up this removal automatically (auth.uid() resolves
// correctly), in the same transaction as the delete — no separate audit
// insert needed here.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (already added for the
//                        other billing functions — shared project-wide)
// (SUPABASE_URL and SUPABASE_ANON_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
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

// Runs as the calling user (their own JWT, forwarded), not the service
// role — RLS applies exactly as it would for a direct client call, and
// auth.uid() inside any trigger fired by these requests resolves to this
// user, not null.
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

async function stripePatch(path: string, params: Record<string, string>): Promise<Response> {
  return await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "POST",
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

  let locationId = "";
  try {
    const body = await req.json();
    locationId = String(body?.locationId ?? "");
  } catch {
    // no/invalid body — locationId stays empty, caught below
  }
  if (!locationId) return jsonResponse({ error: "locationId is required." }, 400);

  try {
    const memberRes = await userDb(
      authHeader,
      `memberships?user_id=eq.${encodeURIComponent(user.id)}` +
        `&select=role,organisations(id,plan_tier,stripe_subscription_item_id)`,
    );
    const members = await memberRes.json();
    const membership = members?.[0];
    if (!membership || (membership.role !== "owner" && membership.role !== "manager")) {
      return jsonResponse({ error: "Only owners and managers can remove locations." }, 403);
    }
    const org = membership.organisations;
    if (org.plan_tier !== "multi") {
      return jsonResponse({ error: "Only multi-venue organisations can remove locations here." }, 400);
    }

    // Scope the delete to this org too — belt-and-braces alongside the
    // membership/role check above (and alongside RLS itself, which already
    // enforces org_id = my_org_id() on this request).
    const deleteRes = await userDb(
      authHeader,
      `locations?id=eq.${encodeURIComponent(locationId)}&org_id=eq.${encodeURIComponent(org.id)}`,
      { method: "DELETE", headers: { Prefer: "return=representation" } },
    );
    if (!deleteRes.ok) {
      const detail = await deleteRes.text();
      const blocked = /foreign key|violates|restrict/i.test(detail);
      return jsonResponse(
        { error: blocked ? "This location has stocktakes and can't be removed." : "Could not remove location." },
        400,
      );
    }
    const deleted = await deleteRes.json();
    if (!deleted.length) return jsonResponse({ error: "Location not found." }, 404);

    if (org.stripe_subscription_item_id) {
      const countRes = await userDb(authHeader, `locations?org_id=eq.${encodeURIComponent(org.id)}&select=id`, {
        headers: { Prefer: "count=exact" },
      });
      const contentRange = countRes.headers.get("content-range") ?? "";
      const quantity = Number(contentRange.split("/")[1]) || (await countRes.json()).length;

      const stripeRes = await stripePatch(`subscription_items/${org.stripe_subscription_item_id}`, {
        quantity: String(quantity),
      });
      if (!stripeRes.ok) {
        throw new Error(`Stripe quantity update failed: ${stripeRes.status} ${await stripeRes.text()}`);
      }
    }

    return jsonResponse({ removed: true });
  } catch (err) {
    console.error("remove-location failed:", err);
    return jsonResponse({ error: "Could not remove location" }, 500);
  }
});
