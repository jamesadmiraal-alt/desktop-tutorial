// Gantry multi-venue concurrent-seat billing — runs as a Supabase Edge Function.
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
//   RESEND_API_KEY     - optional; enables the confirmation email. Without it
//                        the seat change still works and _shared/email.ts
//                        no-ops, so a missing key never breaks billing.
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";
import { ADMIN_URL, brandedHtml, mailFooter, sendEmail } from "../_shared/email.ts";

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

async function stripeGet(path: string): Promise<Response> {
  return await fetch(`https://api.stripe.com/v1/${path}`, {
    headers: { Authorization: `Bearer ${STRIPE_SECRET_KEY}` },
  });
}

// Stripe reports amounts in a currency's minor unit, and how many minor units
// make one major unit varies — most are 100, but a handful are 1. Getting this
// wrong would overstate a JPY figure by 100x in an email about money, so the
// zero-decimal set is spelled out rather than assumed.
const ZERO_DECIMAL = new Set([
  "bif", "clp", "djf", "gnf", "jpy", "kmf", "krw", "mga",
  "pyg", "rwf", "ugx", "vnd", "vuv", "xaf", "xof", "xpf",
]);

function formatMoney(minorUnits: number, currency: string): string {
  const code = (currency ?? "aud").toLowerCase();
  const major = ZERO_DECIMAL.has(code) ? minorUnits : minorUnits / 100;
  try {
    return new Intl.NumberFormat("en-AU", {
      style: "currency",
      currency: code.toUpperCase(),
      minimumFractionDigits: ZERO_DECIMAL.has(code) ? 0 : 2,
    }).format(major);
  } catch {
    // Unknown currency code — better a bare number than a thrown email.
    return `${major.toFixed(ZERO_DECIMAL.has(code) ? 0 : 2)} ${code.toUpperCase()}`;
  }
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
      `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(id,name,plan_tier,stripe_subscription_id,stripe_subscription_item_id,concurrent_seats,seats_increased_at)`,
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

    const currentSeats = Number(org.concurrent_seats ?? 0);
    if (seats === currentSeats) {
      // Nothing to do, and worth short-circuiting rather than issuing a
      // no-op Stripe PATCH that could still generate a proration line.
      return jsonResponse({ concurrentSeats: seats });
    }

    // Minimum-term pre-check, deliberately BEFORE the Stripe PATCH below.
    // enforce_seat_minimum_term() (schema.sql) is the real boundary; this exists
    // so we never lower Stripe's quantity for a write Postgres is about to
    // reject — that would stop billing for seats the owner is still committed
    // to, turning the rule into a revenue leak instead of enforcing it. Same
    // relationship as app.html's countryChangeEligible() to
    // enforce_country_cooldown: a courtesy, not the enforcement.
    const SEAT_MIN_TERM_DAYS = 30;
    if (seats < currentSeats && org.seats_increased_at) {
      const eligibleAt = new Date(
        new Date(org.seats_increased_at).getTime() + SEAT_MIN_TERM_DAYS * 86400000,
      );
      if (Date.now() < eligibleAt.getTime()) {
        return jsonResponse({
          error: `Added seats are billed for a minimum of one month. You can reduce below ${currentSeats} seat${currentSeats === 1 ? "" : "s"} from ${eligibleAt.toISOString().slice(0, 10)} onwards.`,
          seatsFloor: currentSeats,
          eligibleAt: eligibleAt.toISOString(),
        }, 409);
      }
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
      headers: { Prefer: "return=representation" },
      body: JSON.stringify({ concurrent_seats: seats }),
    });
    if (!updateRes.ok) {
      const bodyText = await updateRes.text();
      let pg: { code?: string; message?: string } = {};
      try { pg = JSON.parse(bodyText); } catch { /* not a PostgREST error body */ }

      // Stripe's quantity already moved. Put it back before returning, whatever
      // the reason — without this, a rejected reduction silently stops billing
      // for seats the org still holds, which is worse than the original drift
      // this code merely warned about. Best effort: if the rollback itself
      // fails there's nothing better to do than log it loudly.
      const rollback = await stripePatch(`subscription_items/${org.stripe_subscription_item_id}`, {
        quantity: String(1 + currentSeats),
      });
      if (!rollback.ok) {
        console.error(
          "set-seat-count: Stripe rollback FAILED, quantity now out of sync for org",
          org.id, await rollback.text(),
        );
      }

      // P0001 (raise_exception) is one of our own plpgsql guards, and its
      // message is written for the owner to read — pass it straight through
      // rather than burying it in a generic 500. Anything else is a real fault
      // and keeps the opaque treatment.
      if (pg.code === "P0001" && pg.message) {
        return jsonResponse({ error: pg.message }, 409);
      }
      throw new Error(`concurrent_seats update failed: ${updateRes.status} ${bodyText}`);
    }
    const updated = await updateRes.json();
    const updatedOrg = Array.isArray(updated) ? updated[0] : updated;

    // The audit triggers all no-op for service-role writes (auth.uid() is
    // null), and log_organisations_change has no concurrent_seats branch
    // anyway — so this is the only place a seat change, the most directly
    // billable operator action in the product, can be recorded at all. Same
    // explicit-log pattern the other Edge Functions use.
    const auditRes = await db(`audit_log`, {
      method: "POST",
      body: JSON.stringify({
        org_id: org.id,
        org_label: org.name ?? "Unknown organisation",
        actor_id: user.id,
        actor_label: user.email ?? "Unknown user",
        action: "organisation.seats_changed",
        entity_type: "organisation",
        entity_id: org.id,
        target_label: org.name ?? "Unknown organisation",
        before: { concurrent_seats: currentSeats },
        after: {
          concurrent_seats: seats,
          seats_increased_at: updatedOrg?.seats_increased_at ?? null,
        },
      }),
    });
    if (!auditRes.ok) {
      // Don't fail the request over the log: the seat change and the charge have
      // both already happened, and reporting failure now would invite a retry
      // that double-charges. Loud console error instead.
      console.error("set-seat-count: audit_log insert failed for org", org.id, await auditRes.text());
    }

    // ---- Confirmation email to the owner ----
    //
    // Everything below is best-effort and deliberately after the point of no
    // return: the seat count and the Stripe quantity have both already changed,
    // so nothing here may fail the request. An owner who gets no email but whose
    // seats did change is mildly annoyed; one who gets an error and retries could
    // be charged twice.
    //
    // The figures come from Stripe's upcoming invoice, NOT from config.js.
    // set-seat-count passes no proration_behavior, so Stripe applies its default
    // `create_prorations`: the adjustment for the remainder of the current period
    // is added as line items on the NEXT invoice rather than charged immediately.
    // That's why the copy below says "your next invoice will be…" and never
    // "you have been charged" — the latter would be plainly untrue, and a
    // locally-computed figure would be wrong for any mid-cycle change anyway.
    try {
      let invoiceLine = "";
      if (org.stripe_subscription_id) {
        const invRes = await stripeGet(
          `invoices/upcoming?subscription=${encodeURIComponent(org.stripe_subscription_id)}`,
        );
        if (invRes.ok) {
          const inv = await invRes.json();
          const total = formatMoney(Number(inv.amount_due ?? 0), inv.currency ?? "aud");
          const when = inv.next_payment_attempt ?? inv.period_end;
          const dateStr = when
            ? new Date(Number(when) * 1000).toISOString().slice(0, 10)
            : null;
          // Sum only the proration lines, so the part-period adjustment can be
          // stated separately from the recurring total.
          const prorations = (inv.lines?.data ?? [])
            .filter((l: { proration?: boolean }) => l.proration)
            .reduce((sum: number, l: { amount?: number }) => sum + Number(l.amount ?? 0), 0);

          invoiceLine = dateStr
            ? `Your next invoice, on ${dateStr}, will be ${total}.`
            : `Your next invoice will be ${total}.`;
          if (prorations !== 0) {
            invoiceLine += `\nThat includes ${formatMoney(Math.abs(prorations), inv.currency ?? "aud")}`
              + (prorations > 0 ? " added" : " credited")
              + " for the rest of the current billing period.";
          }
        } else {
          console.error("set-seat-count: upcoming invoice lookup failed:", invRes.status, await invRes.text());
        }
      }

      const added = seats > currentSeats;
      const termEnd = updatedOrg?.seats_increased_at
        ? new Date(new Date(updatedOrg.seats_increased_at).getTime() + SEAT_MIN_TERM_DAYS * 86400000)
            .toISOString().slice(0, 10)
        : null;

      const lines = [
        `${added ? "Added" : "Removed"} ${Math.abs(seats - currentSeats)} `
          + `${Math.abs(seats - currentSeats) === 1 ? "person" : "people"} for `
          + `${org.name ?? "your organisation"}.`,
        "",
        `Extra people counting at once: ${currentSeats} → ${seats}`,
        "Your own login is always included — this covers everyone else counting at the same time.",
        "",
      ];
      if (invoiceLine) lines.push(invoiceLine, "");
      // Only state the minimum term when it actually binds, i.e. on an increase.
      // Repeating it after a decrease would be noise at best and misleading at
      // worst, since a decrease doesn't start a new term.
      if (added && termEnd) {
        lines.push(
          `Added seats are billed for a minimum of one month, so this level is held until ${termEnd}.`,
          "You can add more at any time; adding restarts the month.",
          "",
        );
      }
      lines.push("Manage " + ADMIN_URL);

      // The HTML half says the same things in fewer words. The plain-text body
      // above keeps the fuller detail (invoice line, term end) because it is
      // also the archive copy someone forwards to a bookkeeper.
      const htmlParagraphs = [
        `${added ? "Added" : "Removed"} ${Math.abs(seats - currentSeats)} `
          + `${Math.abs(seats - currentSeats) === 1 ? "person" : "people"} for `
          + `${org.name ?? "your organisation"}. Extra people counting at once: ${currentSeats} → ${seats}.`,
        "Your own login is always included — this covers everyone else counting at the same time.",
      ];
      if (invoiceLine) htmlParagraphs.push(invoiceLine);
      if (added && termEnd) {
        htmlParagraphs.push(
          `Each added person is billed for a minimum of one month, so this level is held until ${termEnd}.`,
        );
      }

      const result = await sendEmail({
        to: user.email ?? "",
        subject: "Concurrent seats updated",
        text: lines.join("\n") + mailFooter(),
        html: brandedHtml({
          title: "Concurrent seats updated",
          paragraphs: htmlParagraphs,
          ctaLabel: "Open the admin console",
          ctaHref: ADMIN_URL,
        }),
      });
      if (!result.sent) {
        console.error("set-seat-count: confirmation email not sent:", result.provider, result.error);
      }
    } catch (mailErr) {
      // Swallowed on purpose — see the note above. The seat change stands.
      console.error("set-seat-count: confirmation email threw:", mailErr);
    }

    return jsonResponse({
      concurrentSeats: seats,
      seatsIncreasedAt: updatedOrg?.seats_increased_at ?? null,
    });
  } catch (err) {
    console.error("set-seat-count failed:", err);
    return jsonResponse({ error: "Could not update seat count" }, 500);
  }
});
