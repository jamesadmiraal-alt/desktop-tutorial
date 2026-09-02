# Getting Gantry's email working

Gantry sends two unrelated kinds of email, from two different places, and they
break in different ways. Knowing which is which saves an afternoon:

| Kind | Sent by | Examples | Fails as |
|---|---|---|---|
| **Auth** | Supabase Auth's mailer | Confirm your signup, reset your password | Rate-limited, or in spam |
| **App** | Our Edge Functions, via `_shared/email.ts` | Thanks for upgrading, all seats in use | Silently not sent |

Both are currently limited by the same missing piece.

---

## 0. The prerequisite: the domain

**`gantrystocktake.com`** was purchased on 2026-09-01 and is the sending domain.
Until it is *verified* with the mail provider, nothing below reaches a real
customer. This is not a preference, it is how sending works:

- Resend's `onboarding@resend.dev` can only deliver to the address that owns the
  Resend account. Fine for testing, useless in production — your customers get
  nothing and you get no error.
- Postmark refuses to send at all until a sender signature is verified.
- Supabase's built-in mailer is explicitly for development. It is heavily rate
  limited and its deliverability is poor; venues signing up on a Friday night
  will not get their confirmation.

`jamesadmiraal-alt.github.io` could never have been the sender — it is not
yours to prove ownership of at the DNS level, which is exactly why the domain
was needed. Verify `gantrystocktake.com` with the mail provider (step 1) and
everything else here takes about twenty minutes.

The published contact address is **support@gantrystocktake.com** — it appears in
`privacy.html`, `terms.html` and the POS form's confirmation on `index.html`.
Set up somewhere for it to land (a forward to your normal inbox is fine) before
those pages go live, or the first person to email gets silence.

Pointing the *website* at the domain is a separate job and not required for
email: GitHub Pages custom domains need their own DNS records and a `CNAME`
file, and the app's Stripe redirect URLs and Supabase allowlist (step 4) would
all need updating to match. Do it deliberately, not as a side effect of setting
up mail.

---

## 1. Create the sending account

Resend is the assumed provider — `_shared/email.ts` supports both Resend and
Postmark, and picks by which secret exists, so switching later is a Dashboard
change and no code edit.

1. Sign up at [resend.com](https://resend.com).
2. **Domains → Add Domain**, enter `gantrystocktake.com`.
3. Add the DNS records it gives you (usually DKIM plus a return-path CNAME) at
   your registrar. Verification is normally minutes, occasionally hours.
4. **Do add SPF and DMARC** if Resend prompts you. Without them a good share of
   mail to Outlook and Gmail lands in spam, and you will spend a week blaming
   the app.
5. **API Keys → Create**, with send permission. Copy the `re_...` value — it is
   shown once.

---

## 2. Wire up the app email (Edge Functions)

Supabase Dashboard → **Edge Functions → Secrets**, on project
`vfixdchbkmqryfhirphx`:

| Secret | Value |
|---|---|
| `RESEND_API_KEY` | the `re_...` key from step 1 |
| `MAIL_FROM` | `Gantry <hello@gantrystocktake.com>` — must be on the verified domain |

Secrets are project-wide, so every function picks them up. **No redeploy is
needed** for functions that are already deployed: they read the secret at call
time. `sendEmail()` returns `{ sent: false }` rather than throwing when neither
secret exists, which is why the upgrade email could ship before the domain did.

Verify by triggering one:

```sh
# a test-mode checkout is the real path; the log line tells you either way
supabase functions logs super-stripewebhooks --project-ref vfixdchbkmqryfhirphx
```

Look for `upgrade welcome not sent: none no provider configured` (secret
missing) versus nothing at all (sent).

---

## 3. Fix the auth email rate limit (this is the actual fix)

**This is the step that solves "email rate limited".** Supabase's built-in
mailer has a low hourly cap that cannot be raised — the fix is to stop using it
and point Auth at your own provider's SMTP.

Supabase Dashboard → **Authentication → Emails → SMTP Settings** → enable custom
SMTP:

| Field | Resend's value |
|---|---|
| Host | `smtp.resend.com` |
| Port | `465` (or `587`) |
| Username | `resend` |
| Password | your `re_...` API key |
| Sender email | `hello@gantrystocktake.com` (or any address on the verified domain) |
| Sender name | `Gantry` |

Save, then send yourself a password reset from the app to prove it works.

Once custom SMTP is on, the rate limits under **Authentication → Rate Limits**
become yours to set rather than Supabase's development defaults.

---

## 4. Let the confirmation link come back to the app

`app.html` sends `emailRedirectTo` on signup, pointing at itself. Supabase
**ignores a redirect that is not allowlisted** and silently uses the Site URL
instead — which looks exactly like the app ignoring the setting.

Supabase Dashboard → **Authentication → URL Configuration**:

- **Site URL**: `https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html`
- **Redirect URLs**, add both:
  - `https://jamesadmiraal-alt.github.io/desktop-tutorial/app.html`
  - `http://127.0.0.1:8899/app.html` (local testing only — remove before live)

The app handles the arrival by itself: supabase-js reads the session out of the
URL, and `app.html` boots straight into org setup. No landing page is needed.

---

## 5. The confirmation email itself

Supabase Dashboard → **Authentication → Emails → Templates → Confirm signup**.
The default is Supabase's, not Gantry's, and it shows.

**Subject**

```
Confirm your email to start counting
```

**Body** (`{{ .ConfirmationURL }}` is the only variable that must survive):

```html
<h2>You're one click away</h2>

<p>Thanks for signing up to Gantry — barcode stocktaking for hospitality.</p>

<p>Confirm your email address and we'll take you straight back to the app to
set up your venue:</p>

<p>
  <a href="{{ .ConfirmationURL }}"
     style="display:inline-block;padding:12px 22px;border-radius:10px;
            background:#059669;color:#ffffff;font-weight:600;
            text-decoration:none">Confirm my email</a>
</p>

<p style="color:#6b7280;font-size:14px">
  Your free trial covers 5 products per stocktake, with as many stocktakes as
  you like and exports included. No card needed.
</p>

<p style="color:#6b7280;font-size:14px">
  If the button doesn't work, paste this into your browser:<br>
  {{ .ConfirmationURL }}
</p>

<p style="color:#9ca3af;font-size:13px">
  Didn't sign up? Ignore this email and nothing happens.
</p>
```

Keep the plain-link fallback. A meaningful share of venue email clients strip
styled buttons, and a confirmation email whose only action is invisible is
indistinguishable from one that never arrived.

---

## 6. What to check when someone says "I never got the email"

In order, because this is the order they actually fail:

1. **Spam folder.** Especially before SPF/DMARC are set.
2. **The address they typed.** The app's "Check your email" dialog shows it back
   to them precisely so this is quick to rule out.
3. **Resend → Emails.** It logs every send, with bounces and rejections.
4. **Supabase → Authentication → Logs.** If nothing appears, the send never
   started — usually SMTP settings, not the provider.
5. **Rate limit.** If several people signed up at once and only the first got
   through, custom SMTP (step 3) is not on.

---

## Related

- [`STRIPE-SETUP.md`](STRIPE-SETUP.md) — billing, Payment Links, the webhook
- [`supabase/functions/_shared/email.ts`](supabase/functions/_shared/email.ts) —
  the provider-agnostic sender, and the one place to change to switch providers
