// In-app "Help & support" — runs as a Supabase Edge Function.
//
// Called by app.html's openHelp() form (Account → Help & support, the ⋯ sheet's
// "Get help with this count", and the "Get help" link on a red error toast).
// Emails support@ (Cloudflare Email Routing → James's Gmail) with Reply-To set
// to the caller, so pressing Reply in Gmail answers the customer.
//
// JWT verification stays ON. Who is asking, which org, which plan and which
// role are all looked up HERE from the caller's own session — the client's
// `context` is only what the app could see (screen, open take, last error,
// device), and is labelled as such in the email.
//
// The row comes first, the email second. support_requests holds the whole
// message, so a provider outage (or no provider configured) loses nothing:
// the app says "Saved — we'll still see it" and James can read the table.
// Never a 500 for a mail failure; a 500 only means the row didn't save either.
//
// Throttle: 5 per user per hour, counted from support_requests. Over that, a
// friendly 429.
//
// Deploy:
//   supabase functions deploy contact-support
// Secrets: RESEND_API_KEY (or POSTMARK_*), MAIL_FROM — already set. Optional
// CONTACT_TO (defaults to support@gantrystocktake.com).
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected.)
// Needs migration 20261015_01_support_requests.sql.

import { createClient } from "npm:@supabase/supabase-js@2";
import { brandedHtml, mailFooter, sendEmail } from "../_shared/email.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const DEFAULT_TO = "support@gantrystocktake.com";
const MAX_SUBJECT = 120;
const MAX_MESSAGE = 4000;
const MAX_CONTEXT = 4000;
const PER_HOUR = 5;

const PLAN_LABELS: Record<string, string> = {
  trial: "Trial",
  single: "Solo",
  multi: "Team",
  pending: "Lapsed / pending",
};

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function clip(s: string, n: number): string {
  return s.length <= n ? s : s.slice(0, n);
}

// The client's context, flattened to "Label: value" lines. Only known keys,
// each clipped, so a client can't stuff the email with arbitrary fields.
const CONTEXT_FIELDS: Array<[string, string]> = [
  ["version", "App version"],
  ["screen", "Screen"],
  ["take", "Open count"],
  ["error", "Last error"],
  ["what", "Doing"],
  ["userAgent", "Device / browser"],
];
function contextLines(raw: unknown): string[] {
  const c = (raw && typeof raw === "object") ? raw as Record<string, unknown> : {};
  const out: string[] = [];
  for (const [key, label] of CONTEXT_FIELDS) {
    const v = c[key];
    if (v === undefined || v === null || v === "") continue;
    out.push(`${label}: ${clip(String(v).replace(/\s+/g, " ").trim(), 600)}`);
  }
  return out;
}

function adelaideNow(): string {
  return new Intl.DateTimeFormat("en-AU", {
    timeZone: "Australia/Adelaide",
    dateStyle: "medium",
    timeStyle: "short",
  }).format(new Date()) + " (Adelaide)";
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
  if (authError || !user) return jsonResponse({ error: "Not signed in" }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "bad json" }, 400);
  }
  const subject = clip(String(body.subject ?? "").replace(/\s+/g, " ").trim(), MAX_SUBJECT);
  const message = clip(String(body.message ?? "").trim(), MAX_MESSAGE);
  if (!message) return jsonResponse({ error: "Write a message first" }, 400);
  const ctx = contextLines(body.context);
  const contextText = clip(ctx.join("\n"), MAX_CONTEXT);

  const admin = createClient(SUPABASE_URL, SERVICE_KEY);

  // Throttle before anything is stored or sent.
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count, error: countErr } = await admin
    .from("support_requests").select("id", { count: "exact", head: true })
    .eq("user_id", user.id).gte("created_at", since);
  if (countErr) {
    console.error("contact-support: throttle check failed:", countErr);
    return jsonResponse({ error: "Could not send right now — email support@gantrystocktake.com" }, 500);
  }
  if ((count ?? 0) >= PER_HOUR) {
    return jsonResponse({
      error: "That's 5 messages this hour — we've got them. We'll reply by email; " +
        "if it's urgent, email support@gantrystocktake.com.",
    }, 429);
  }

  // Server-side facts: never the client's word for these.
  const { data: member } = await admin
    .from("memberships").select("role, org_id").eq("user_id", user.id).maybeSingle();
  let orgName = "(no organisation yet)";
  let plan = "—";
  if (member?.org_id) {
    const { data: org } = await admin
      .from("organisations").select("name, plan_tier").eq("id", member.org_id).maybeSingle();
    if (org) {
      orgName = org.name || "(unnamed organisation)";
      plan = PLAN_LABELS[org.plan_tier] ?? String(org.plan_tier ?? "—");
    }
  }
  const role = member?.role ?? "—";
  const email = user.email ?? "";

  // The row first: from here on the message can't be lost.
  const { data: row, error: insErr } = await admin.from("support_requests").insert({
    user_id: user.id,
    org_id: member?.org_id ?? null,
    subject: subject || null,
    message,
    context: contextText || null,
  }).select("id").single();
  if (insErr || !row) {
    console.error("contact-support: insert failed:", insErr);
    return jsonResponse({ error: "Could not send right now — email support@gantrystocktake.com" }, 500);
  }

  const facts = [
    `From: ${email || "(no email on account)"}`,
    `Role: ${role}`,
    `Organisation: ${orgName}`,
    `Plan: ${plan}`,
    ...ctx,
    `Time: ${adelaideNow()}`,
  ];
  const mailSubject = `Gantry help: ${orgName} — ${subject || "(no subject)"}`;

  try {
    const result = await sendEmail({
      to: (Deno.env.get("CONTACT_TO") ?? DEFAULT_TO).trim() || DEFAULT_TO,
      subject: clip(mailSubject, 200),
      replyTo: email || undefined,
      text: [message, "", "— Context —", ...facts].join("\n") + mailFooter(),
      html: brandedHtml({
        title: subject || "Help request",
        paragraphs: [message, "— Context —", ...facts],
      }),
    });
    if (result.sent) {
      await admin.from("support_requests").update({ emailed_at: new Date().toISOString() }).eq("id", row.id);
    } else {
      console.log("contact-support: not sent:", result.provider, result.error ?? "");
    }
    return jsonResponse({ sent: result.sent, saved: true });
  } catch (err) {
    console.error("contact-support: send threw:", err);
    return jsonResponse({ sent: false, saved: true });
  }
});
