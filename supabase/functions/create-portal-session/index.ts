// Barscan Stripe billing portal — runs as a Supabase Edge Function.
//
// Called by the app's "Manage subscription" button. Identifies the caller
// from their own Supabase session (unlike stripe-webhook, this function
// keeps "Enforce JWT verification" ON — see STRIPE-SETUP.md), looks up their
// Stripe customer, and returns a Stripe-hosted Customer Portal session URL
// where they can view invoices, update payment method, or cancel.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_SECRET_KEY  - the "sk_..." secret key (test mode to start)
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const STRIPE_SECRET_KEY = Deno.env.get("STRIPE_SECRET_KEY") ?? "";

const RETURN_URL = "https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html?billing_updated=1";

// The app (github.io, or a native WebView origin) calls this cross-origin,
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
    const profileRes = await db(`profiles?id=eq.${encodeURIComponent(user.id)}&select=stripe_customer_id`);
    const profiles = await profileRes.json();
    const customerId = profiles?.[0]?.stripe_customer_id;
    if (!customerId) {
      return new Response(
        JSON.stringify({ error: "No billing account found for this user yet." }),
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
