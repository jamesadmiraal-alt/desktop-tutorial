// Tells an organisation's owner that a team member was turned away by the
// concurrent-seat limit — runs as a Supabase Edge Function.
//
// Called by app.html the moment claim_seat() returns false (see
// refreshOrgStatus there). Without this, hitting the seat limit is completely
// invisible to whoever can fix it: claim_seat() writes nothing on the false
// path, and the blocked staff member's only recourse is to phone someone.
//
// The security-sensitive part is deliberately NOT here. record_seat_denial()
// (schema.sql) re-derives the denial from the same seat pool and staleness cutoff
// claim_seat() uses, writes the audit row, and decides atomically whether this
// call is inside the throttle window. This function trusts nothing the client
// says — it passes no seat counts, no org id, no recipient. All it does is turn
// that verdict into an email. Consequences worth stating:
//   * A staff member cannot spam their owner by calling this in a loop: the
//     second call in a 30-minute window returns notify=false, and a call made
//     when a seat is actually free returns denied=false and records nothing.
//   * A staff member cannot use it to discover anyone's email address — the
//     owner's address is resolved server-side and never returned to the caller.
//
// JWT verification stays ON: this acts on behalf of whoever calls it, and that
// identity is the whole basis of the check.
//
// Required secrets: none, strictly. Email sending is enabled by adding
// RESEND_API_KEY (or POSTMARK_SERVER_TOKEN) — see _shared/email.ts. Until one
// exists the denial is still verified, logged and throttled; only the send is
// skipped, and the response says so.
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";
import { mailFooter, sendEmail } from "../_shared/email.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const APP_URL = "https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html";

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: CORS_HEADERS });

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Not signed in" }, 401);

  try {
    // Forwarded caller JWT, so auth.uid()/my_role() inside the function resolve
    // to the person who was actually blocked.
    const { data: verdict, error: rpcError } = await userClient.rpc("record_seat_denial");
    if (rpcError) {
      console.error("notify-seat-denied: record_seat_denial failed:", rpcError);
      return jsonResponse({ error: "Could not record the seat denial" }, 500);
    }

    if (!verdict?.denied) {
      // Not actually blocked. Returned as a normal 200 — the client isn't doing
      // anything wrong, it just raced a seat becoming free.
      return jsonResponse({ notified: false, reason: verdict?.reason ?? "not denied" });
    }
    if (!verdict.notify) {
      return jsonResponse({ notified: false, reason: "already notified recently" });
    }

    // Resolve the owner's address with the Admin API: auth.users is not exposed
    // through PostgREST at all, and the caller (staff) could not read it anyway.
    if (!verdict.owner_user_id) {
      console.error("notify-seat-denied: org has no owner membership", verdict);
      return jsonResponse({ notified: false, reason: "no owner on record" });
    }
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: ownerData, error: ownerError } = await admin.auth.admin.getUserById(
      verdict.owner_user_id as string,
    );
    const ownerEmail = ownerData?.user?.email;
    if (ownerError || !ownerEmail) {
      console.error("notify-seat-denied: could not resolve owner email:", ownerError);
      return jsonResponse({ notified: false, reason: "owner email unavailable" });
    }

    const orgName = (verdict.org_name as string) ?? "your organisation";
    const blocked = (verdict.blocked_person as string) ?? "A team member";
    const purchased = Number(verdict.seats_purchased ?? 0);
    const occupied = Number(verdict.seats_occupied ?? 0);

    // The zero-seat case is worth calling out separately rather than reporting
    // "0 of 0 seats in use", which reads like a bug. A multi-venue org that
    // never bought seats blocks EVERY non-owner, and an owner who has just
    // upgraded has no reason to expect that.
    const body = purchased === 0
      ? [
          `${blocked} couldn't log in to Gantry: ${orgName} has no extra concurrent seats.`,
          "",
          "On the Multi-venue plan your own login is always free, but each additional",
          "person who needs to be logged in at the same time needs a seat.",
          "",
          "Add seats in the admin console under Concurrent seats.",
        ].join("\n")
      : [
          `${blocked} couldn't log in to Gantry: all of ${orgName}'s concurrent seats are in use.`,
          "",
          `Seats purchased: ${purchased}`,
          `In use right now: ${occupied}`,
          "",
          "Either ask someone to log out, or add another seat in the admin console",
          "under Concurrent seats. You can see who's currently logged in there too.",
        ].join("\n");

    const result = await sendEmail({
      to: ownerEmail,
      subject: purchased === 0
        ? `${orgName}: a team member can't log in — no seats purchased`
        : `${orgName}: all concurrent seats are in use`,
      text: body + "\n\n" + APP_URL + mailFooter(),
    });

    // A send failure is NOT an error for this request: the denial has already
    // been verified, logged and throttled, and the caller only invoked this as a
    // courtesy after being shown the seats-full screen. Reporting 500 would make
    // the client think something it can't fix went wrong.
    if (!result.sent) {
      console.error("notify-seat-denied: email not sent:", result.provider, result.error);
    }
    return jsonResponse({ notified: result.sent, provider: result.provider, reason: result.error });
  } catch (err) {
    console.error("notify-seat-denied failed:", err);
    return jsonResponse({ error: "Could not notify the owner" }, 500);
  }
});
