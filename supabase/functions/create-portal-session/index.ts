// Gantry Stripe billing portal — runs as a Supabase Edge Function.
//
// Called by the app's "Manage subscription" button. Identifies the caller
// from their own Supabase session (unlike stripe-webhook, this function
// keeps "Enforce JWT verification" ON — see STRIPE-SETUP.md), looks up their
// ORGANISATION's Stripe customer (billing is org-scoped, not per-user — see
// the org-model planning doc), and returns a Stripe-hosted Customer Portal
// session URL where they can view invoices, update payment method, or
// cancel. Owner-only: a staff/manager member shouldn't be able to open the
// org's billing portal.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (test mode to start)
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

// Where Stripe sends the customer after they close the billing portal. Also
// customer-facing, so it uses the domain rather than the github.io build host —
// the same reason as _shared/email.ts's SITE and app.html's SITE_URL.
//
// NOTE: the Payment Links' own after-payment redirect is Stripe Dashboard
// config, not code, and is still pointed at github.io — see STRIPE-SETUP.md §2.
const RETURN_URL = "https://gantrystocktake.com/app.html?billing_updated=1";

// The app (a browser origin, or a native WebView origin) calls this cross-origin,
// so the browser sends a preflight OPTIONS request before the real POST —
// without these headers it never even reaches the code below.
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

async function db(path: string): Promise<Response> {
  return await fetch(`${SUPABASE_URL}/rest/v1/${path}`, {
    headers: {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
    },
  });
}

async function stripe(path: string, params: Record<string, string>): Promise<Response> {
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
    const memberRes = await db(
      `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(stripe_customer_id)`,
    );
    const members = await memberRes.json();
    const membership = members?.[0];
    if (!membership) {
      return new Response(
        JSON.stringify({ error: "You don't belong to an organisation yet." }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }
    if (membership.role !== "owner") {
      return new Response(
        JSON.stringify({ error: "Only the organisation owner can manage billing." }),
        { status: 403, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }
    const customerId = membership.organisations?.stripe_customer_id;
    if (!customerId) {
      return new Response(
        JSON.stringify({ error: "No billing account found for this organisation yet." }),
        { status: 400, headers: { ...CORS_HEADERS, "Content-Type": "application/json" } },
      );
    }

    const portalRes = await stripe("billing_portal/sessions", {
      customer: customerId,
      return_url: RETURN_URL,
    });
    if (!portalRes.ok) {
      const detail = await portalRes.text();
      throw new Error(`Stripe portal session failed: ${portalRes.status} ${detail}`);
    }
    const portal = await portalRes.json();

    return new Response(JSON.stringify({ url: portal.url }), {
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  } catch (err) {
    console.error("create-portal-session failed:", err);
    return new Response(JSON.stringify({ error: "Could not open billing portal" }), {
      status: 500,
      headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
    });
  }
});
