// Gantry account deletion — runs as a Supabase Edge Function.
//
// Called by the app's "Delete account" confirmation. Identifies the caller
// from their own Supabase session (keeps "Enforce JWT verification" ON, same
// as create-portal-session — see STRIPE-SETUP.md).
//
// Billing (and org data — locations/stocktakes/stocktake_items) is org-
// scoped, not per-user, so this is no longer a plain "cancel my subscription,
// delete me, let the FKs cascade" flow (profiles/stocktakes/stocktake_items
// don't cascade from auth.users any more — created_by/scanned_by are
// `on delete set null`, deliberately, so a departing user doesn't take the
// org's data with them — see schema.sql). Three cases, based on the caller's
// membership:
//   1. Sole member of their org (any role) — this IS "delete my whole org":
//      cancel its Stripe subscription if any, then delete the organisations
//      row (cascades locations/stocktakes/stocktake_items), then the user.
//   2. Sole owner with other members still present — blocked. They need to
//      promote a co-owner (or remove the other members) first.
//   3. Anything else (departing staff/manager, or an owner with a
//      co-owner) — just delete the user; their membership cascades away
//      with them, the org and its Stripe subscription are untouched.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (test mode to start)
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

// The app (github.io, or a native WebView origin) calls this cross-origin,
// so the browser sends a preflight OPTIONS request before the real POST —
// without these headers it never even reaches the code below.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

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

async function stripeGet(path: string): Promise<Response> {
  return await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
  });
}

async function stripeDelete(path: string): Promise<Response> {
  return await fetch(`https://api.stripe.com/v1/${path}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
  });
}

async function cancelActiveSubscriptions(customerId: string): Promise<void> {
  const res = await stripeGet(
    `subscriptions?customer=${encodeURIComponent(customerId)}&status=active`,
  );
  if (!res.ok) throw new Error(`listing subscriptions failed: ${res.status} ${await res.text()}`);
  const { data: subs } = await res.json();
  for (const sub of subs ?? []) {
    // Cancel now, not at period end — the account is being deleted immediately.
    const del = await stripeDelete(`subscriptions/${sub.id}`);
    if (!del.ok) throw new Error(`cancelling subscription ${sub.id} failed: ${del.status} ${await del.text()}`);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: CORS_HEADERS });
  }

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Not signed in" }), {
      status: 401,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }

  try {
    const memberRes = await db(`memberships?user_id=eq.${encodeURIComponent(user.id)}&select=org_id,role`);
    const members = await memberRes.json();
    const membership = members?.[0];

    if (membership) {
      const orgMembersRes = await db(
        `memberships?org_id=eq.${encodeURIComponent(membership.org_id)}&select=user_id,role`,
      );
      const orgMembers: { user_id: string; role: string }[] = await orgMembersRes.json();

      if (orgMembers.length === 1) {
        // Sole member — deleting the account means dissolving the org too.
        const orgRes = await db(
          `organisations?id=eq.${encodeURIComponent(membership.org_id)}&select=stripe_customer_id`,
        );
        const orgs = await orgRes.json();
        const customerId = orgs?.[0]?.stripe_customer_id;
        if (customerId) await cancelActiveSubscriptions(customerId);

        const orgDeleteRes = await db(`organisations?id=eq.${encodeURIComponent(membership.org_id)}`, {
          method: "DELETE",
        });
        if (!orgDeleteRes.ok) {
          throw new Error(`organisation delete failed: ${orgDeleteRes.status} ${await orgDeleteRes.text()}`);
        }
      } else if (membership.role === "owner") {
        const hasOtherOwner = orgMembers.some((m) => m.user_id !== user.id && m.role === "owner");
        if (!hasOtherOwner) {
          return new Response(
            JSON.stringify({
              error:
                "You're the only owner of this organisation — promote a teammate to owner first, or remove the other members, before deleting your account.",
            }),
            { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
          );
        }
      }
      // else: departing staff/manager, or an owner with a co-owner —
      // nothing else to do; deleting the user below removes their
      // membership via cascade, and the org's subscription (if any) was
      // never theirs to touch.
    }

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;

    return new Response(JSON.stringify({ deleted: true }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("delete-account failed:", err);
    return new Response(JSON.stringify({ error: "Could not delete account" }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
