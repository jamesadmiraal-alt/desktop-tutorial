// Public Contact us form on the marketing landing page (index.html).
//
// Anonymous visitors submit name (optional), email, and message. This function
// emails support@ (CF Email Routing → James's Gmail) via _shared/email.ts, with
// Reply-To set to the submitter so a reply goes straight to them.
//
// JWT verification is OFF (see supabase/config.toml). The anon key in the
// browser is still sent as apikey; there is no signed-in user. Rate-limiting /
// spam: honeypot field + basic length/email checks. Do not trust client fields
// for the recipient — CONTACT_TO (optional secret) or the hardcoded support@
// address only.
//
// Deploy:
//   supabase functions deploy submit-contact --no-verify-jwt
// Secrets already used by other mailers: RESEND_API_KEY (or POSTMARK_*), MAIL_FROM.
// Optional: CONTACT_TO (defaults to support@gantrystocktake.com).

import { brandedHtml, mailFooter, sendEmail } from "../_shared/email.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DEFAULT_TO = "support@gantrystocktake.com";
const MAX_NAME = 120;
const MAX_EMAIL = 254;
const MAX_MESSAGE = 4000;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function clip(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n);
}

function looksLikeEmail(s: string): boolean {
  // Deliberately loose — enough to catch typos, not an RFC parser.
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") {
    return new Response("method not allowed", { status: 405, headers: CORS_HEADERS });
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "bad json" }, 400);
  }

  // Honeypot: pretend success so bots learn nothing useful.
  const honey = String(body.company_website ?? "").trim();
  if (honey) return jsonResponse({ sent: true, honeypot: true });

  const name = clip(String(body.name ?? "").trim(), MAX_NAME);
  const email = clip(String(body.email ?? "").trim(), MAX_EMAIL);
  const message = clip(String(body.message ?? "").trim(), MAX_MESSAGE);

  if (!email || !looksLikeEmail(email)) {
    return jsonResponse({ error: "email required" }, 400);
  }
  if (!message) {
    return jsonResponse({ error: "message required" }, 400);
  }

  const to = (Deno.env.get("CONTACT_TO") ?? DEFAULT_TO).trim() || DEFAULT_TO;
  const who = name || "(no name)";
  const subject = `Gantry contact: ${who}`;
  const text = [
    "New Contact us submission from gantrystocktake.com",
    "",
    `Name: ${who}`,
    `Email: ${email}`,
    "",
    "Message:",
    message,
  ].join("\n");

  try {
    const result = await sendEmail({
      to,
      subject,
      text: text + mailFooter(),
      replyTo: email,
      html: brandedHtml({
        title: "Contact us",
        paragraphs: [
          `From: ${who} <${email}>`,
          message,
        ],
      }),
    });

    if (!result.sent) {
      console.log("submit-contact: not sent:", result.provider, result.error ?? "");
      // Tell the browser it failed so they can retry or mailto — unlike
      // fire-and-forget product mails, the form's only job is delivery.
      return jsonResponse({
        sent: false,
        provider: result.provider,
        error: result.error ?? "not sent",
      }, 502);
    }
    return jsonResponse({ sent: true, provider: result.provider });
  } catch (err) {
    console.error("submit-contact threw:", err);
    return jsonResponse({ sent: false, error: "send failed" }, 502);
  }
});
