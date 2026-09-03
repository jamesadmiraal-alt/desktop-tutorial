// Welcomes someone who has just created an organisation on the trial — runs as
// a Supabase Edge Function.
//
// Called by app.html's completeOrgSetup() immediately after
// create_organisation() succeeds, and ONLY on that path:
//   * not after join_organisation() — joining an existing org is not a new
//     trial, and the person joining is staff, not the customer;
//   * not from the Stripe webhook — that sends the paid welcome instead, and a
//     "here's your trial" mail arriving after someone has just paid would read
//     as a billing error.
// The skip-the-trial button routes through the same completeOrgSetup(), so it
// gets this too, which is correct: the organisation really is created on
// 'trial' and stays there until checkout completes.
//
// It takes NO arguments. The recipient is the caller's own address from their
// own session, so there is no version of this call that emails anyone else, and
// nothing the client says can change what is sent.
//
// JWT verification stays ON: the caller's identity is the only input.
//
// Required secrets: none, strictly. Sending is enabled by adding
// RESEND_API_KEY (or POSTMARK_SERVER_TOKEN) — see _shared/email.ts. Until one
// exists this returns { sent: false } and says why, which is why it could ship
// before the sending domain was verified.
// (SUPABASE_URL and SUPABASE_ANON_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";
import { APP_URL, brandedHtml, mailFooter, sendEmail } from "../_shared/email.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

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

const TITLE = "You're on Gantry. Five products per count.";
const PARAGRAPHS = [
  "You're in. Scan a barcode, type the qty, export CSV into the stocktake import you already use.",
  "Liquor retail, hotels, pubs, clubs.",
  "Trial five products per stocktake, exports included, no card.",
  "No hardware. No consultant.",
];

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
  if (authError || !user) return jsonResponse({ error: "Not signed in" }, 401);
  if (!user.email) return jsonResponse({ sent: false, reason: "no address on this account" });

  try {
    // Plain text carries the URL inline, since there is no anchor to label.
    const text = [TITLE, "", ...PARAGRAPHS, "", `Open ${APP_URL}`].join("\n");
    const result = await sendEmail({
      to: user.email,
      subject: TITLE,
      text: text + mailFooter(),
      html: brandedHtml({
        title: TITLE,
        paragraphs: PARAGRAPHS,
        ctaLabel: "Open Gantry",
        ctaHref: APP_URL,
      }),
    });
    if (!result.sent) {
      console.log("send-trial-welcome: not sent:", result.provider, result.error ?? "");
    }
    return jsonResponse({ sent: result.sent, provider: result.provider });
  } catch (err) {
    // Never a 500. The organisation has already been created by the time the
    // client calls this, and the caller treats the whole thing as
    // fire-and-forget — a mail provider having a bad minute must not turn a
    // successful signup into a visible failure.
    console.error("send-trial-welcome threw:", err);
    return jsonResponse({ sent: false, reason: "send failed" });
  }
});
