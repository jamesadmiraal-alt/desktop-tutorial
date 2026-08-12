// Barscan team member edit / password reset — runs as a Supabase Edge Function.
//
// Owner-only. Two independent, optional actions in one call: rename
// (updates profiles.full_name — a plain field, not security-sensitive
// enough to warrant its own security-definer RPC, so this writes it
// directly via the service role, same shape as delete-account's plain
// service-role writes) and/or reset password (generates a fresh random
// 6-digit code via the Admin API, same spirit as create-team-member's
// initial password — the new hire can still change it themselves later
// via the existing "Forgot password?" flow).
//
// Explicitly checks the target userId belongs to the CALLER's own org
// before touching anything — without this, an owner could edit an
// arbitrary stranger's name or reset their password by guessing a UUID,
// since the writes below go through the service role and bypass RLS.
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

// Service role — the actual writes (profiles update, audit_log insert)
// run here, after the org-scope check above has already confirmed the
// target belongs to the caller's own org.
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

function randomSixDigitCode(): string {
  return String(Math.floor(100000 + Math.random() * 900000));
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
  let fullName: string | null = null;
  let resetPassword = false;
  try {
    const body = await req.json();
    targetUserId = String(body?.userId ?? "");
    if (typeof body?.fullName === "string" && body.fullName.trim()) fullName = body.fullName.trim();
    resetPassword = !!body?.resetPassword;
  } catch {
    // no/invalid body — fields stay empty, caught below
  }
  if (!targetUserId) return jsonResponse({ error: "userId is required." }, 400);
  if (!fullName && !resetPassword) return jsonResponse({ error: "Nothing to update." }, 400);

  try {
    const callerRes = await userDb(authHeader, `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(id,name)`);
    const callers = await callerRes.json();
    const caller = callers?.[0];
    if (!caller || caller.role !== "owner") {
      return jsonResponse({ error: "Only the owner can edit team members." }, 403);
    }
    const orgId = caller.organisations.id;

    const targetRes = await db(`memberships?user_id=eq.${encodeURIComponent(targetUserId)}&select=org_id`);
    const targets = await targetRes.json();
    if (!targets?.[0] || targets[0].org_id !== orgId) {
      return jsonResponse({ error: "That person isn't a member of your organisation." }, 404);
    }

    const actorLabelRes = await db(`profiles?id=eq.${encodeURIComponent(user.id)}&select=full_name`);
    const actorProfiles = await actorLabelRes.json();
    const actorLabel = actorProfiles?.[0]?.full_name || user.email || "Unknown user";

    const targetEmailRes = await db(`profiles?id=eq.${encodeURIComponent(targetUserId)}&select=full_name`);
    const targetProfiles = await targetEmailRes.json();
    const previousName = targetProfiles?.[0]?.full_name ?? null;

    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    let tempPassword: string | undefined;

    if (fullName) {
      const updateRes = await db(`profiles?id=eq.${encodeURIComponent(targetUserId)}`, {
        method: "PATCH",
        body: JSON.stringify({ full_name: fullName }),
      });
      if (!updateRes.ok) throw new Error(`profile update failed: ${updateRes.status} ${await updateRes.text()}`);

      await db(`audit_log`, {
        method: "POST",
        body: JSON.stringify({
          org_id: orgId, org_label: caller.organisations.name, actor_id: user.id, actor_label: actorLabel,
          action: "membership.updated_by_owner", entity_type: "membership", entity_id: targetUserId,
          target_label: fullName, before: { full_name: previousName }, after: { full_name: fullName },
        }),
      });
    }

    if (resetPassword) {
      tempPassword = randomSixDigitCode();
      const { error: pwError } = await admin.auth.admin.updateUserById(targetUserId, { password: tempPassword });
      if (pwError) throw pwError;

      await db(`audit_log`, {
        method: "POST",
        body: JSON.stringify({
          org_id: orgId, org_label: caller.organisations.name, actor_id: user.id, actor_label: actorLabel,
          action: "membership.password_reset_by_owner", entity_type: "membership", entity_id: targetUserId,
          target_label: fullName || previousName || "team member",
        }),
      });
    }

    return jsonResponse({ ok: true, tempPassword });
  } catch (err) {
    console.error("update-team-member failed:", err);
    return jsonResponse({ error: "Could not update team member" }, 500);
  }
});
