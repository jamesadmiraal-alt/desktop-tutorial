// Tells Gantry (support@) about export templates venues build, the requests
// they make, and how their first imports went — runs as a Supabase Edge
// Function.
//
// Information gathering, not alerting: when a venue builds a template for a POS
// Gantry has no official template for, that template — and whether its first
// file imported cleanly — is the evidence for making it an official one.
//
// THE RECORD IS public.export_template_submissions, NOT THIS EMAIL. Every row
// exists before this runs: template saves write theirs by trigger, in the same
// transaction as the save; requests and feedback are inserted by app.html. This
// function only turns unsent rows into mail and stamps emailed_at. If it never
// runs, fails, or no provider is configured (true as of 2026-10-11), nothing is
// lost — the rows wait, and go out the next time it is called with a working
// provider. See the Verify query in migration 20261011_01 for reading them
// directly.
//
// It sweeps rather than taking a submission id: the caller's own JWT selects
// the unsent rows, so RLS ("read own org submissions") IS the membership check —
// a caller can only ever cause their own org's rows to be sent, and can't name
// anyone else's. Sweeping also retries rows an earlier call failed to send.
//
// Rate limit: at most 10 emails per org per rolling hour, counted from
// emailed_at. Rows over the limit stay unsent and go out on a later call.
// (People's submissions are separately capped at 30/hour by the database.)
//
// JWT verification stays ON — the caller's identity is the whole basis of the
// RLS scoping above. That is the platform default; config.toml states it
// explicitly anyway, because submit-contact (the function this is modelled on)
// has it OFF, and copying that setting here would make this callable by anyone
// with the public anon key.
//
// Deploy:
//   supabase functions deploy notify-export-template
// Secrets: none required. Email needs RESEND_API_KEY (or POSTMARK_SERVER_TOKEN)
// and MAIL_FROM — see _shared/email.ts. Optional CONTACT_TO (defaults to
// support@gantrystocktake.com), shared with submit-contact.
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected.)

import { createClient } from "npm:@supabase/supabase-js@2";
import { brandedHtml, mailFooter, sendEmail } from "../_shared/email.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const DEFAULT_TO = "support@gantrystocktake.com";
const EMAILS_PER_ORG_PER_HOUR = 10;

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// The POS names for the subject line James filters on. Must list the same codes
// and labels as KNOWN_POS in export-engine.js — scripts/test-export-engine.js
// parses this object and fails if they differ. (A Deno function can't load the
// browser's global-assigning script, hence the copy, hence the test.)
const POS_LABELS: Record<string, string> = {
  bepoz: "Bepoz",
  hl: "H&L",
  myob_exo: "MYOB EXO",
  lightspeed_r: "Lightspeed Retail (R-Series)",
  lightspeed_k: "Lightspeed Restaurant (K-Series)",
  shopfront: "Shopfront",
  tower: "Tower Systems Retailer",
  swiftpos: "SwiftPOS",
  impos: "Impos",
  square: "Square",
  other: "Other",
};

const KIND_LABELS: Record<string, string> = {
  created: "new template",
  updated: "template edited",
  request: "request",
  import_feedback: "import feedback",
};

const ZERO_LABELS: Record<string, string> = {
  keep: "keep as scanned",
  strip_one: "remove one leading zero (13/14-digit only)",
  strip_all: "remove all leading zeros",
  pad: "pad with zeros",
};

type Row = Record<string, unknown>;

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function str(v: unknown): string {
  return v === null || v === undefined ? "" : String(v);
}

function posName(code: unknown, other: unknown): string {
  const c = str(code);
  if (!c) return "No POS given";
  if (c === "other") return str(other).trim() ? `Other: ${str(other).trim()}` : "Other";
  return POS_LABELS[c] ?? c;
}

// The template, in a form a person can read and rebuild from.
function describeTemplate(t: Row | null): string[] {
  if (!t) return ["(no template attached)"];
  const rules = (t.barcode_rules ?? {}) as Row;
  const zero = str(rules.leading_zero) || "keep";
  const cols = Array.isArray(t.columns) ? (t.columns as Row[]) : [];
  const delimiter = t.delimiter === "\t" ? "tab" : "comma";
  const behaviour = t.import_behaviour === "add"
    ? "adds to existing counts"
    : t.import_behaviour === "replace" ? "replaces existing counts" : "not sure";
  return [
    `Template: ${str(t.name)}${t.is_system ? " (Gantry system template)" : ""}`,
    `Verified: ${t.verified ? "yes" : "no"}`,
    `Identifier: ${str(t.identifier_type) || "barcode"}`
      + (t.identifier_fallback ? `, falling back to ${str(t.identifier_fallback)}` : ""),
    `Leading zeros: ${ZERO_LABELS[zero] ?? zero}`
      + (zero === "pad" ? ` to ${str(rules.pad_length) || "13"} digits` : ""),
    `Header row: ${t.include_header ? "yes" : "no"}`,
    `Delimiter: ${delimiter}`,
    `File: .${str(t.file_extension) || "csv"}, BOM ${t.bom ? "ON" : "off"}`,
    `Filename pattern: ${str(t.file_name_pattern) || "(default)"}`,
    `POS import: ${behaviour}`,
    "Columns:",
    ...cols.map((c, i) =>
      `  ${i + 1}. "${str(c.header)}" <- ${str(c.source)}`
      + (c.source === "fixed" ? ` = "${str(c.value)}"` : "")
    ),
  ];
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

  try {
    // The caller's JWT: RLS limits this to their own org's rows.
    const { data: pending, error: pendingError } = await userClient
      .from("export_template_submissions")
      .select("*")
      .is("emailed_at", null)
      .order("created_at", { ascending: true })
      .limit(EMAILS_PER_ORG_PER_HOUR);
    if (pendingError) {
      console.error("notify-export-template: could not read submissions:", pendingError);
      return jsonResponse({ error: "Could not read submissions" }, 500);
    }
    const rows = (pending ?? []) as Row[];
    if (!rows.length) return jsonResponse({ sent: 0, pending: 0 });

    const orgId = str(rows[0].org_id);
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);

    const hourAgo = new Date(Date.now() - 60 * 60 * 1000).toISOString();
    const { count: recent } = await admin
      .from("export_template_submissions")
      .select("id", { count: "exact", head: true })
      .eq("org_id", orgId)
      .gte("emailed_at", hourAgo);
    const allowance = Math.max(0, EMAILS_PER_ORG_PER_HOUR - (recent ?? 0));
    if (!allowance) {
      return jsonResponse({ sent: 0, pending: rows.length, reason: "hourly email limit reached" });
    }

    const { data: org } = await admin
      .from("organisations").select("name, plan_tier").eq("id", orgId).maybeSingle();
    const orgName = str(org?.name) || "(unknown organisation)";
    // Display names, not the stored keys (plans renamed 21 Oct 2026).
    const PLAN_LABELS: Record<string, string> = { single: "Solo", multi: "Team", trial: "Trial", pending: "No plan" };
    const tier = str(org?.plan_tier);
    const plan = PLAN_LABELS[tier] ?? (tier || "unknown");
    const to = (Deno.env.get("CONTACT_TO") ?? DEFAULT_TO).trim() || DEFAULT_TO;

    let sent = 0;
    let provider = "none";
    for (const row of rows.slice(0, allowance)) {
      // Who: name from profiles, address from the Admin API (auth.users is not
      // exposed through PostgREST). Resolved server-side, never sent by a client.
      let who = "(unknown)";
      let whoEmail = "";
      if (row.created_by) {
        const { data: prof } = await admin
          .from("profiles").select("full_name").eq("id", str(row.created_by)).maybeSingle();
        const { data: u } = await admin.auth.admin.getUserById(str(row.created_by));
        whoEmail = u?.user?.email ?? "";
        who = [str(prof?.full_name), whoEmail ? `<${whoEmail}>` : ""].filter(Boolean).join(" ") || who;
      }
      let stocktake = "";
      if (row.stocktake_id) {
        const { data: st } = await admin
          .from("stocktakes").select("name").eq("id", str(row.stocktake_id)).maybeSingle();
        stocktake = str(st?.name);
      }

      const kind = str(row.kind);
      const pos = posName(row.pos_system, row.pos_other);
      // "Gantry export template:" first, then the POS — so a filter on that
      // prefix catches every one of these, and the POS sorts them.
      const subject = `Gantry export template: ${pos} — ${KIND_LABELS[kind] ?? kind}`;

      const header = [
        `Organisation: ${orgName}`,
        `Plan: ${plan}`,
        `Submitted by: ${who}`,
        `POS: ${pos}`,
        `Kind: ${KIND_LABELS[kind] ?? kind}`,
        `When: ${str(row.created_at)}`,
      ];
      const feedback = kind === "import_feedback"
        ? [
          "",
          `Stocktake: ${stocktake || "(deleted)"}`,
          `Imported cleanly: ${row.import_ok === true ? "YES" : row.import_ok === false ? "NO" : "not said"}`,
          ...(row.import_ok === false ? [`Lines that didn't match: ${str(row.failed_lines) || "not said"}`] : []),
        ]
        : [];
      const notes = str(row.notes).trim() ? ["", "Notes:", str(row.notes).trim()] : [];
      const samples = str(row.sample_lines).trim()
        ? ["", "Sample lines from their POS file:", ...str(row.sample_lines).trim().split(/\r?\n/).map((l) => `  ${l}`)]
        : [];
      const templateLines = row.template_snapshot
        ? ["", ...describeTemplate(row.template_snapshot as Row)]
        : [];

      const text = [...header, ...feedback, ...notes, ...samples, ...templateLines].join("\n");

      const result = await sendEmail({
        to,
        subject,
        text: text + mailFooter(),
        ...(whoEmail ? { replyTo: whoEmail } : {}),
        html: brandedHtml({
          title: subject,
          // brandedHtml escapes every paragraph — template headers, notes and
          // sample lines are venue-typed text and must stay text.
          paragraphs: [
            header.join(" · "),
            ...[...feedback, ...notes, ...samples, ...templateLines].filter((l) => l.trim()),
          ],
        }),
      });
      provider = result.provider;

      if (!result.sent) {
        // Non-fatal by design (see _shared/email.ts). Leave emailed_at NULL so
        // the row goes out on a later call, and stop: if this one couldn't be
        // sent, the rest won't be either.
        console.log("notify-export-template: not sent:", result.provider, result.error ?? "");
        break;
      }
      const { error: stampError } = await admin
        .from("export_template_submissions")
        .update({ emailed_at: new Date().toISOString() })
        .eq("id", str(row.id));
      if (stampError) console.error("notify-export-template: sent but could not stamp:", stampError);
      sent++;
    }

    // Always 200. The submission is saved whatever happens here, and the app
    // treats this call as fire-and-forget — an email problem must never read
    // to a venue as "your template didn't save".
    return jsonResponse({ sent, pending: rows.length - sent, provider });
  } catch (err) {
    console.error("notify-export-template threw:", err);
    return jsonResponse({ sent: 0, error: "notify failed" });
  }
});
