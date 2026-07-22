// Barscan account deletion — runs as a Supabase Edge Function.
//
// Called by the app's "Delete account" confirmation. Identifies the caller
// from their own Supabase session (keeps "Enforce JWT verification" ON, same
// as create-portal-session — see STRIPE-SETUP.md), immediately cancels any
// active Stripe subscription so they're never billed again, then deletes the
// Supabase user. profiles/stocktakes/stocktake_items all cascade-delete off
// auth.users (see schema.sql) so no separate cleanup is needed here.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (test mode to start)
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

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
  if (req.method !== "POST") return new Response("method not allowed", { status: 405 });

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Not signed in" }), { status: 401 });
  }

  try {
    const profileRes = await db(`profiles?id=eq.${encodeURIComponent(user.id)}&select=stripe_customer_id`);
    const profiles = await profileRes.json();
    const customerId = profiles?.[0]?.stripe_customer_id;
    if (customerId) await cancelActiveSubscriptions(customerId);

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;

    return new Response(JSON.stringify({ deleted: true }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("delete-account failed:", err);
    return new Response(JSON.stringify({ error: "Could not delete account" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});
