-- In-app support: every message sent from app.html's Help form, kept whether
-- or not the email to support@ goes out.
--
-- Written ONLY by the contact-support Edge Function, with the service key. RLS
-- is on with no policies and every client privilege revoked, so no browser can
-- read or write a row — not even its own. That is deliberate: the function is
-- the throttle (5 per user per hour, counted here) and the only place the
-- org/plan/role are resolved, so a direct insert would bypass both.
--
-- The message and context are stored, not just a count: the function saves the
-- row BEFORE emailing, so a provider outage loses nothing. emailed_at is
-- stamped only on a real send — rows with it null are messages James has not
-- received by email (read them with the Verify query below).
--
-- Additive: one new table and an index. Safe to run twice. NOT mirrored into
-- schema.sql, same as pos_interest: schema.sql drops and rebuilds tables, and
-- a rebuild must never delete customers' support messages.
--
-- Run BEFORE deploying contact-support; push app.html after both.

create table if not exists public.support_requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade,
  org_id      uuid references public.organisations(id) on delete set null,
  subject     text,
  message     text not null,
  context     text,
  created_at  timestamptz not null default now(),
  emailed_at  timestamptz,
  constraint support_requests_subject_len check (subject is null or length(subject) <= 120),
  constraint support_requests_message_len check (length(message) between 1 and 4000),
  constraint support_requests_context_len check (context is null or length(context) <= 4000)
);

create index if not exists support_requests_user_recent
  on public.support_requests (user_id, created_at desc);

alter table public.support_requests enable row level security;
revoke all on public.support_requests from anon, authenticated;

-- Verify:
--   select count(*) from public.support_requests;                -- 0 on a fresh run
--   select has_table_privilege('authenticated', 'public.support_requests', 'select');  -- false
--
-- Messages that did not go out by email, newest first:
--   select r.created_at, p.full_name, u.email, o.name as org, r.subject, r.message, r.context
--   from public.support_requests r
--   join auth.users u on u.id = r.user_id
--   left join public.profiles p on p.id = r.user_id
--   left join public.organisations o on o.id = r.org_id
--   where r.emailed_at is null
--   order by r.created_at desc;
