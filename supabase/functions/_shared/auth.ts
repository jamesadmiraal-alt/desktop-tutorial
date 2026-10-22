// Who is calling — the one way every JWT-ON Edge Function here finds out.
//
// Reads the caller's own access token from the Authorization header and asks
// Supabase Auth about THAT token, with the service key (admin.auth.getUser(jwt)).
// The pattern it replaces — a client built on SUPABASE_ANON_KEY with the
// header forwarded, then auth.getUser() with no argument — depended on the
// legacy anon key and on supabase-js picking the token up from a global
// header, and every failure came back as one bare "Not signed in".
//
// Two distinct 401s, so the app can tell them apart:
//   no_auth_header   nothing was sent — a bug or a logged-out page.
//   session_invalid  a token was sent and Auth rejected it (expired, revoked,
//                    signed out elsewhere). The app refreshes the session once
//                    and retries; if that fails too, it shows this message.
// The Auth error's status is logged (never the token) so a burst of rejections
// can be told apart from a key problem in the function logs.
//
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.

import { createClient, type User } from "npm:@supabase/supabase-js@2";

export type AuthOk = { user: User; token: string };
export type AuthFail = { response: Response };

const SESSION_ENDED = "Your session has ended — sign in again";

function json(body: unknown, status: number, headers: Record<string, string>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...headers, "Content-Type": "application/json" },
  });
}

/** The caller, or a ready-made 401 to return. `corsHeaders` are the calling
 *  function's own, so the browser can read the error body. */
export async function requireUser(
  req: Request,
  corsHeaders: Record<string, string>,
): Promise<AuthOk | AuthFail> {
  const raw = (req.headers.get("Authorization") ?? "").trim();
  const m = /^Bearer\s+(.+)$/i.exec(raw);
  const token = m ? m[1].trim() : "";
  if (!token) {
    return { response: json({ error: "Not signed in", code: "no_auth_header" }, 401, corsHeaders) };
  }
  const admin = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) {
    console.log("requireUser: token rejected", error?.status ?? "", error?.message ?? "no user");
    return { response: json({ error: SESSION_ENDED, code: "session_invalid" }, 401, corsHeaders) };
  }
  return { user: data.user, token };
}
