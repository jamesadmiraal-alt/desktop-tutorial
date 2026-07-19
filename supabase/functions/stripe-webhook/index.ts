// Barscan Stripe webhook — runs as a Supabase Edge Function.
//
// Flips profiles.is_pro when Stripe reports a completed checkout, and off
// again when a subscription is cancelled. Deploy instructions: STRIPE-SETUP.md.
//
// Required secrets (Supabase Dashboard -> Edge Functions -> Secrets):
//   STRIPE_WEBHOOK_SECRET  - the "whsec_..." signing secret of the webhook endpoint
// (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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

async function setPro(userId: string, isPro: boolean, customerId?: string) {
  const body: Record<string, unknown> = { is_pro: isPro };
  if (customerId) body.stripe_customer_id = customerId;
  const res = await db(`profiles?id=eq.${encodeURIComponent(userId)}`, {
    method: "PATCH",
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`profiles update failed: ${res.status} ${await res.text()}`);
}

async function setProByCustomer(customerId: string, isPro: boolean) {
  const res = await db(`profiles?stripe_customer_id=eq.${encodeURIComponent(customerId)}`, {
    method: "PATCH",
    body: JSON.stringify({ is_pro: isPro }),
  });
  if (!res.ok) throw new Error(`profiles update failed: ${res.status} ${await res.text()}`);
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
        // The app appends ?client_reference_id=<supabase user id> to the
        // Payment Link, so it comes back here identifying who paid.
        const userId = session.client_reference_id;
        const customerId = typeof session.customer === "string" ? session.customer : undefined;
        if (userId) await setPro(userId, true, customerId);
        else console.error("checkout.session.completed without client_reference_id", session.id);
        break;
      }
      case "customer.subscription.deleted": {
        const sub = event.data.object;
        const customerId = typeof sub.customer === "string" ? sub.customer : sub.customer?.id;
        if (customerId) await setProByCustomer(customerId, false);
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
