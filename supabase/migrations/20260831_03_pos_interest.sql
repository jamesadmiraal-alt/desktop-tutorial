-- Expression-of-interest capture for POS systems Gantry doesn't map yet.
--
-- The landing page posts here with the PUBLIC anon key, so the security model is
-- the whole design: anyone may write a submission, nobody holding that key may
-- read one back. Submissions contain a business name and a contact email — a
-- readable table would be a public list of hospitality leads.
--
-- Additive and safe to run twice. Touches nothing else in the schema. NOT
-- mirrored into schema.sql: that file is a full rebuild guarded to refuse a
-- populated project, and this table is unrelated to the app's own data model —
-- adding it there would mean a rebuild drops real submissions.

create table if not exists public.pos_interest (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  email text not null,
  business_name text,
  pos_system text,
  -- Free text, only filled when pos_system = 'Other'.
  pos_other text,
  -- The form offers ranges (1, 2-5, 6-20, 20+) because an operator does not
  -- count venues precisely when filling in a form. Stored as the LOWER BOUND of
  -- the chosen range: 1, 2, 6, 20. Enough to sort leads by size, and honest
  -- about being approximate.
  venue_count int,
  format_notes text,
  source text default 'landing'
);

alter table public.pos_interest enable row level security;

-- The ONLY policy on this table, deliberately.
--
-- No select, update or delete policy exists, and none should be added. RLS
-- denies any command with zero matching policies, so the anon key can write a
-- submission and can never read, alter or remove one — including its own. Read
-- them from the Supabase dashboard or with the service role.
--
-- If a "let people see their own submission" feature is ever wanted, it needs a
-- real identity to scope by. Do not add a select policy keyed on the submitted
-- email: anyone could type any email and read that person's entry.
drop policy if exists "anon can submit pos interest" on public.pos_interest;
create policy "anon can submit pos interest" on public.pos_interest
  for insert to anon with check (true);

-- Belt and braces alongside RLS. Supabase grants table privileges to anon and
-- authenticated by default, and a future `create policy` for select would
-- otherwise silently become readable. With SELECT revoked at the grant level,
-- a policy alone is not enough to expose these rows.
revoke all on public.pos_interest from anon, authenticated;
grant insert on public.pos_interest to anon;

-- Shape constraints. The client validates too, but the client is a public web
-- page and its checks are a courtesy, not a boundary.
alter table public.pos_interest drop constraint if exists pos_interest_email_check;
alter table public.pos_interest
  add constraint pos_interest_email_check
  check (position('@' in email) > 0 and length(email) < 320);

alter table public.pos_interest drop constraint if exists pos_interest_format_notes_check;
alter table public.pos_interest
  add constraint pos_interest_format_notes_check
  check (format_notes is null or length(format_notes) < 2000);

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- a submission is accepted (this is what the landing page does):
--   insert into public.pos_interest (email, pos_system) values ('a@b.com', 'SwiftPOS');
--
--   -- the constraints bite:
--   insert into public.pos_interest (email) values ('not-an-email');   -- rejected
--   insert into public.pos_interest (email, format_notes)
--     values ('a@b.com', repeat('x', 2000));                           -- rejected
--
--   -- and confirm anon cannot read them back. From the SQL editor:
--   set local role anon;
--   select * from public.pos_interest;   -- permission denied for table pos_interest
--   reset role;
--
--   -- read submissions as the owner:
--   select created_at, email, business_name, pos_system, pos_other,
--          venue_count, format_notes
--     from public.pos_interest order by created_at desc;
