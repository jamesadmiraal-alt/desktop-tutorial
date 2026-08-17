// Outbound transactional email for Gantry's Edge Functions.
//
// Deliberately provider-agnostic. Which provider is used is decided by which
// secret exists, so switching from Resend to Postmark later is a Dashboard
// change plus nothing here — no redeploy of the calling functions, no code edit.
//
// IMPORTANT: with NO provider secret set, sendEmail() does not throw. It logs
// what it would have sent and returns { sent: false, provider: "none" }. That is
// intentional: it lets the whole notification path — detection, throttling,
// audit logging — be deployed and exercised before any email account exists, and
// means a lapsed API key degrades to "notifications stop" rather than "the
// function 500s and the caller thinks the operation failed". Every caller must
// therefore treat a false `sent` as non-fatal, because email is never the
// primary purpose of the request that triggers it.
//
// Secrets (Supabase Dashboard -> Edge Functions -> Secrets), all optional:
//   RESEND_API_KEY         - "re_..."   enables Resend
//   POSTMARK_SERVER_TOKEN  -            enables Postmark (takes precedence)
//   MAIL_FROM              - e.g. "Gantry <alerts@yourdomain.com>"
//
// On MAIL_FROM: Resend's onboarding@resend.dev works with no domain setup but
// can ONLY deliver to the address that owns the Resend account — fine for
// testing, useless in production. Postmark requires a verified sender signature
// before it will send at all.

export type SendResult = {
  sent: boolean;
  provider: "resend" | "postmark" | "none";
  error?: string;
};

export type SendArgs = {
  to: string;
  subject: string;
  /** Plain-text body. Always send one — some clients prefer it, and it's the
   *  accessible fallback. */
  text: string;
  /** Optional HTML body. */
  html?: string;
};

const DEFAULT_FROM = "Gantry <onboarding@resend.dev>";

export async function sendEmail(args: SendArgs): Promise<SendResult> {
  const from = Deno.env.get("MAIL_FROM") ?? DEFAULT_FROM;
  const postmark = Deno.env.get("POSTMARK_SERVER_TOKEN");
  const resend = Deno.env.get("RESEND_API_KEY");

  if (!args.to) return { sent: false, provider: "none", error: "no recipient" };

  if (postmark) return await viaPostmark(postmark, from, args);
  if (resend) return await viaResend(resend, from, args);

  // No provider configured. Log enough to confirm the path ran end to end
  // without leaking the body into logs.
  console.log(
    `sendEmail: no provider secret set — would have sent "${args.subject}" to ${args.to}`,
  );
  return { sent: false, provider: "none", error: "no provider configured" };
}

async function viaResend(apiKey: string, from: string, args: SendArgs): Promise<SendResult> {
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${apiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from,
        to: [args.to],
        subject: args.subject,
        text: args.text,
        ...(args.html ? { html: args.html } : {}),
      }),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error("sendEmail(resend) failed:", res.status, detail);
      return { sent: false, provider: "resend", error: `${res.status} ${detail}` };
    }
    return { sent: true, provider: "resend" };
  } catch (err) {
    console.error("sendEmail(resend) threw:", err);
    return { sent: false, provider: "resend", error: String(err) };
  }
}

async function viaPostmark(token: string, from: string, args: SendArgs): Promise<SendResult> {
  try {
    const res = await fetch("https://api.postmarkapp.com/email", {
      method: "POST",
      headers: {
        "X-Postmark-Server-Token": token,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        From: from,
        To: args.to,
        Subject: args.subject,
        TextBody: args.text,
        ...(args.html ? { HtmlBody: args.html } : {}),
        MessageStream: Deno.env.get("POSTMARK_MESSAGE_STREAM") ?? "outbound",
      }),
    });
    if (!res.ok) {
      const detail = await res.text();
      console.error("sendEmail(postmark) failed:", res.status, detail);
      return { sent: false, provider: "postmark", error: `${res.status} ${detail}` };
    }
    return { sent: true, provider: "postmark" };
  } catch (err) {
    console.error("sendEmail(postmark) threw:", err);
    return { sent: false, provider: "postmark", error: String(err) };
  }
}

/** Shared plain-text signature so both notifications end the same way. */
export function mailFooter(): string {
  return [
    "",
    "—",
    "Gantry · https://jamesadmiraal-alt.github.io/desktop-tutorial/",
    "You're receiving this because you're the owner of this organisation.",
  ].join("\n");
}
