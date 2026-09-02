// Gantry owner-provisioned team member creation — runs as a Supabase Edge Function.
//
// Lets an org owner create a teammate's login directly from admin.html —
// email, name, and a role (manager = gets admin.html access, staff =
// doesn't) — instead of the self-service two-factor join-code flow
// (join_organisation() in schema.sql). The temp password is a random
// 6-digit numeric code, same spirit as the existing join/daily codes:
// easy to read aloud or hand over on paper. The new hire can change it
// later via the app's existing "Forgot password?" email flow — nothing
// new needed there.
//
// Two privileged steps, in order: (1) create the auth.users row itself
// via the Admin API — something Postgres can't do, hence an Edge
// Function at all — then (2) call add_team_member() (schema.sql),
// forwarding the OWNER's own JWT rather than the service role, so
// auth.uid() inside that function resolves to the owner (for its role
// check and its audit_log entry), not null. If step 2 fails, step 1 is
// rolled back — an orphaned login with no org membership isn't useful to
// anyone and would be confusing to find later.
//
// Owner only — see add_team_member()'s own check, mirrored here so a
// non-owner gets a clean 403 without ever reaching the Admin API call.
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

// Runs as the calling user (their own JWT, forwarded) — RLS/role checks
// inside any RPC called this way see the real caller, not the service role.
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

  let email = "";
  let fullName = "";
  let role = "";
  try {
    const body = await req.json();
    email = String(body?.email ?? "").trim();
    fullName = String(body?.fullName ?? "").trim();
    role = String(body?.role ?? "");
  } catch {
    // no/invalid body — fields stay empty, caught below
  }
  if (!email || !fullName) return jsonResponse({ error: "Name and email are required." }, 400);
  if (role !== "manager" && role !== "staff") return jsonResponse({ error: "Invalid role." }, 400);

  try {
    const memberRes = await userDb(
      authHeader,
      `memberships?user_id=eq.${encodeURIComponent(user.id)}&select=role,organisations(plan_tier)`,
    );
    const members = await memberRes.json();
    if (!members?.[0] || members[0].role !== "owner") {
      return jsonResponse({ error: "Only the owner can add team members." }, 403);
    }

    // Single-venue is ONE user: the owner. A team is what Multi-venue is for.
    //
    // Refused HERE, before the Admin API is touched, so no auth user is created
    // and rolled back — a half-provisioned account whose email can never be
    // re-used is a worse outcome than a clean refusal. add_team_member() in
    // schema.sql enforces the same rule for anything that reaches the database
    // directly; this exists so the operator gets a readable 403 instead of a
    // raw plpgsql exception, and so nothing is created on the way.
    //
    // Same sentence as the RPC and the Team view — keep the three in step.
    if (members[0]?.organisations?.plan_tier !== "multi") {
      return jsonResponse(
        {
          error:
            "Single-venue is just you — the owner. Multi-venue ($59/mo) lets you set up as many people as you like, and costs $29/mo for each extra person counting at the same time.",
        },
        403,
      );
    }

    const tempPassword = randomSixDigitCode();
    const admin = createClient(SUPABASE_URL, SERVICE_KEY);
    const { data: created, error: createError } = await admin.auth.admin.createUser({
      email,
      password: tempPassword,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (createError || !created.user) {
      const msg = createError?.message ?? "";
      const duplicate = /already registered|already exists|already been registered/i.test(msg);
      if (!duplicate) return jsonResponse({ error: "Could not create the account." }, 400);

      // The email exists — but existing-and-unattached is the common case (a
      // staff member who started a signup and stopped), not a real conflict.
      // Adopt that account into this org rather than dead-ending: without this
      // the address can never be onboarded, since we can't create it and they
      // can't join. adopt_existing_team_member() (schema.sql) does the owner
      // check, refuses anyone who already has a membership, and delegates the
      // actual membership write to add_team_member(). No password is issued —
      // they keep the credentials they already have.
      const adoptRes = await userDb(authHeader, `rpc/adopt_existing_team_member`, {
        method: "POST",
        body: JSON.stringify({ p_email: email, p_role: role }),
      });
      if (!adoptRes.ok) {
        const detail = await adoptRes.text();
        const taken = /already belongs/i.test(detail);
        return jsonResponse(
          {
            error: taken
              ? "That email already belongs to someone in another organisation."
              : "An account with that email already exists and couldn't be added.",
          },
          400,
        );
      }
      return jsonResponse({ email, adopted: true });
    }

    const rpcRes = await userDb(authHeader, `rpc/add_team_member`, {
      method: "POST",
      body: JSON.stringify({ p_user_id: created.user.id, p_role: role }),
    });
    if (!rpcRes.ok) {
      const detail = await rpcRes.text();
      await admin.auth.admin.deleteUser(created.user.id); // roll back the orphaned login
      const alreadyMember = /duplicate key|already belongs|unique/i.test(detail);
      return jsonResponse(
        { error: alreadyMember ? "That person already belongs to another organisation." : "Could not add this person to the team." },
        400,
      );
    }

    return jsonResponse({ email, tempPassword });
  } catch (err) {
    console.error("create-team-member failed:", err);
    return jsonResponse({ error: "Could not create team member" }, 500);
  }
});
