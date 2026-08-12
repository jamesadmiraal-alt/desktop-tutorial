// Gantry force-log-out — runs as a Supabase Edge Function.
//
// Owner-only. Replaces the plain kick_user() RPC as the client's call site
// for the "Log out" button in admin.html's Concurrent seats card — that RPC
// still exists in schema.sql (and this function still does everything it
// did: org/role check, delete the active_sessions row) but a plain Postgres
// function can't reach the Supabase Auth Admin API, which is the whole
// point of this function existing.
//
// Real, honest limitation stated in schema.sql's kick_user() comment and
// worth repeating here: Supabase access tokens (JWTs) are stateless and
// stay valid for their full lifetime (default ~1hr) regardless of what the
// server does. There's no Admin API call that instantly invalidates one
// already-issued, still-valid token — admin.updateUserById(uid,
// { ban_duration }) is enforced at sign-in/refresh time, not on every
// already-authenticated request. So this closes the gap where a kicked
// user could otherwise just keep refreshing their session forever
// uninterrupted (a real, if modest, hardening), but it does NOT make the
// kick instant — the target's own device still only notices via its next
// heartbeat() call finding its active_sessions row gone (see
// heartbeat()/kick_user() in schema.sql), same soft-kick timing as before.
// Un-banning isn't needed: the 24h ban auto-expires, and a legitimately-
// returning staff member logging back in normally is unaffected by it (the
// seat pool is what actually gates their next login anyway).
//
// (SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)

import { createClient } from "npm:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

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

// Forwarded caller JWT — used only for the owner/org-scope check, so that
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

// Service role — the active_sessions delete and the audit_log insert run
// here, after the org-scope check above has already confirmed the target
// belongs to the caller's own org.
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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== "POST") return new Response("method not allowed", { status: 405, headers: CORS_HEADERS });

  const authHeader = req.headers.get("Authorization") ?? "";
  const userClient = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: "Not signed in" }, 401);

  let targetUserId = "";
  try {
    const body = await req.json();
    targetUserId = String(body?.userId ?? "");
  } catch {
    // no/invalid body — caught below
  }
  if (!targetUserId) return jsonResponse({ error: "userId is required." }, 400);

  try {
    const callerRes = await userDb(authHeader, `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(id,name)`);
    const callers = await callerRes.json();
    const caller = callers?.[0];
    if (!caller || caller.role !== "owner") {
      return jsonResponse({ error: "Only the owner can log out a team member." }, 403);
    }
    const orgId = caller.organisations.id;

    const targetRes = await db(`memberships?user_id=eq.${encodeURIComponent(targetUserId)}&select=org_id`);
    const targets = await targetRes.json();
    if (!targets?.[0] || targets[0].org_id !== orgId) {
      return jsonResponse({ error: "That person isn't a member of your organisation." }, 404);
    }

    await db(`active_sessions?user_id=eq.${encodeURIComponent(targetUserId)}&org_id=eq.${encodeURIComponent(orgId)}`, {
      method: "DELETE",
    });

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { error: banError } = await admin.auth.admin.updateUserById(targetUserId, { ban_duration: "24h" });
    if (banError) throw banError;

    const actorLabelRes = await db(`profiles?id=eq.${encodeURIComponent(user.id)}&select=full_name`);
    const actorProfiles = await actorLabelRes.json();
    const actorLabel = actorProfiles?.[0]?.full_name || user.email || "Unknown user";

    const targetProfileRes = await db(`profiles?id=eq.${encodeURIComponent(targetUserId)}&select=full_name`);
    const targetProfiles = await targetProfileRes.json();
    const targetLabel = targetProfiles?.[0]?.full_name || "team member";

    await db(`audit_log`, {
      method: "POST",
      body: JSON.stringify({
        org_id: orgId, org_label: caller.organisations.name, actor_id: user.id, actor_label: actorLabel,
        action: "membership.force_logged_out_by_owner", entity_type: "membership", entity_id: targetUserId,
        target_label: targetLabel,
      }),
    });

    return jsonResponse({ ok: true });
  } catch (err) {
    console.error("kick-user failed:", err);
    return jsonResponse({ error: "Could not log out this person" }, 500);
  }
});
