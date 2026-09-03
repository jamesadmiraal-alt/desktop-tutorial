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

/** The customer-facing home. Every link in an email points here — never at the
 *  github.io deploy, which is the build host and not the brand. */
export const SITE = "https://gantrystocktake.com";
export const APP_URL = `${SITE}/app.html`;
export const ADMIN_URL = `${SITE}/admin.html`;

/** Shared plain-text signature so every notification ends the same way. */
export function mailFooter(): string {
  return [
    "",
    "—",
    `Gantry · ${SITE}`,
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Branded HTML shell.
//
// Table-based with inline styles, because that is the only thing that renders
// consistently: Outlook's Word engine ignores most modern CSS, and Gmail strips
// <style> blocks entirely on some clients. So no flexbox, no classes, no
// external stylesheet — everything on the element.
//
// The mark is a PNG, not the SVG used everywhere else on the site: Gmail,
// Outlook and Apple Mail all refuse to render SVG in mail. It is generated from
// icons/gantry-mark.svg at 128px and displayed at 40px, which covers 2x and 3x
// screens. Absolutely referenced, since an email has no origin to be relative
// to.
//
// Colours are literals rather than the site's CSS custom properties for the
// same reason: var() does not resolve in an email.
// ---------------------------------------------------------------------------

const PAGE_BG = "#f3f4f6";
const BODY = "#111827";
const MUTED = "#6b7280";
const AMBER = "#fbbf24";
const CARD_BG = "#ffffff";
const MARK_URL = `${SITE}/icons/email-mark.png`;

/** Escapes text for HTML. Every value below is ours today, but an org name or a
 *  venue name will end up in one of these eventually and a stray `<` must not
 *  be able to break the markup. */
function esc(s: string): string {
  return s
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

export type BrandedHtmlArgs = {
  title: string;
  /** One <p> each, in order. Plain text — escaped, so no markup. */
  paragraphs: string[];
  ctaLabel?: string;
  ctaHref?: string;
};

export function brandedHtml(args: BrandedHtmlArgs): string {
  const paras = args.paragraphs.map((p) =>
    `<p style="margin:0 0 14px;font-size:16px;line-height:1.55;color:${BODY}">${esc(p)}</p>`
  ).join("\n            ");

  const cta = args.ctaLabel && args.ctaHref
    ? `
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:22px 0 6px">
              <tr><td style="border-radius:10px;background:${BODY}">
                <a href="${esc(args.ctaHref)}"
                   style="display:inline-block;padding:12px 22px;font-size:16px;font-weight:600;
                          color:#ffffff;text-decoration:none;border-radius:10px">${esc(args.ctaLabel)}</a>
              </td></tr>
            </table>`
    : "";

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${esc(args.title)}</title>
</head>
<body style="margin:0;padding:0;background:${PAGE_BG};
             font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"
         style="background:${PAGE_BG}">
    <tr>
      <td align="center" style="padding:24px 12px">
        <table role="presentation" width="600" cellpadding="0" cellspacing="0" border="0"
               style="width:100%;max-width:600px;background:${CARD_BG};border-radius:14px;overflow:hidden">
          <tr>
            <td style="padding:22px 28px 16px">
              <table role="presentation" cellpadding="0" cellspacing="0" border="0">
                <tr>
                  <td style="padding-right:10px" valign="middle">
                    <!-- alt="" on purpose, and it matters more here than usual.
                         Most email clients block remote images by default, so
                         this often does not load at all — with alt text it
                         renders as a broken-image box with "Gantry" crammed
                         into 40px, which looks worse than nothing. The wordmark
                         beside it already says Gantry, so the image is
                         decorative: empty alt also stops a screen reader
                         announcing the name twice. -->
                    <img src="${MARK_URL}" width="40" height="40" alt=""
                         style="display:block;width:40px;height:40px;border:0">
                  </td>
                  <td valign="middle" style="font-size:22px;font-weight:700;letter-spacing:-0.02em;color:${BODY}">
                    Gantry
                  </td>
                </tr>
              </table>
            </td>
          </tr>
          <tr><td style="padding:0"><div style="height:4px;background:${AMBER};line-height:4px;font-size:0">&nbsp;</div></td></tr>
          <tr>
            <td style="padding:24px 28px 26px">
            <h1 style="margin:0 0 14px;font-size:21px;line-height:1.3;font-weight:700;color:${BODY}">${esc(args.title)}</h1>
            ${paras}${cta}
            </td>
          </tr>
          <tr>
            <td style="padding:0 28px 24px;font-size:13px;line-height:1.5;color:${MUTED}">
              gantrystocktake.com · @gantrystocktake
            </td>
          </tr>
        </table>
      </td>
    </tr>
  </table>
</body>
</html>`;
}
