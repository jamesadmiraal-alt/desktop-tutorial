-- Export template builder: venues build their own export, say which POS it is
-- for, and every template, request and first-import verdict is recorded — so
-- the ones that prove themselves can become official system templates.
--
-- Framed as information gathering, and the schema follows from that:
--   * export_templates gains pos_system / pos_other — a template a venue builds
--     must say which system it feeds, or it teaches us nothing;
--   * export_template_submissions is the RECORD: every template created or
--     edited, every "my system needs something the builder can't do" request,
--     and every "did that file import cleanly?" answer. Email to support@ is a
--     convenience on top (notify-export-template). As of 2026-10-11 no email
--     provider is configured, so for now this table is the only way James sees
--     any of it — see the Verify block for the query;
--   * stocktakes.last_export_template_id lets the app ask about the import of
--     the file a stocktake actually produced, once.
--
-- `verified` stays server-only (it was never in the client GRANT). Every
-- template a venue builds is unverified until Gantry promotes it.
--
-- Additive: two columns and three constraints on export_templates, one new
-- table, one column on stocktakes, three trigger functions, one helper, and
-- record_stocktake_export() re-created with an optional fourth argument. No
-- existing row is changed. Safe to run twice. Mirrored into schema.sql.
--
-- Run BEFORE deploying notify-export-template and BEFORE pushing app.html.
-- The deployed app.html keeps working afterwards: it calls
-- record_stocktake_export() with three named arguments, which the new
-- four-argument version accepts (the fourth defaults to NULL).

-- ---------------------------------------------------------------------------
-- 1. Which POS. One SQL statement of the list, called by both check
-- constraints below so the database can't hold two different lists.
--
-- The codes must match KNOWN_POS in export-engine.js exactly —
-- scripts/test-export-engine.js parses this function and fails if they differ.
-- To add a POS: add it to KNOWN_POS, to this list (create or replace), and to
-- POS_LABELS in notify-export-template, then re-run the test. Note a constraint
-- is not re-checked when the function behind it changes, so REMOVING a code
-- here would leave existing rows holding it; only ever add.
-- ---------------------------------------------------------------------------
create or replace function public.is_known_pos(p text)
returns boolean language sql immutable as $$
  select p in ('bepoz', 'hl', 'myob_exo', 'lightspeed_r', 'lightspeed_k',
               'shopfront', 'tower', 'swiftpos', 'impos', 'square', 'other')
$$;

alter table public.export_templates add column if not exists pos_system text;
alter table public.export_templates add column if not exists pos_other text;

-- Org templates must name their POS. None can exist without one yet — Phase 1
-- had no way to create an org template — but if one does, stop here with the
-- reason rather than failing on the constraint with a less useful message.
do $$
begin
  if exists (select 1 from public.export_templates where not is_system and pos_system is null) then
    raise exception 'export_templates has org templates with no pos_system. Set pos_system on them (or delete them), then re-run.';
  end if;
end $$;

alter table public.export_templates drop constraint if exists export_templates_pos_known;
alter table public.export_templates add constraint export_templates_pos_known
  check (pos_system is null or public.is_known_pos(pos_system));
-- System templates may leave it NULL: the three seeds predate this, and must
-- stay byte-identical (their seed JSON is not touched).
alter table public.export_templates drop constraint if exists export_templates_org_names_pos;
alter table public.export_templates add constraint export_templates_org_names_pos
  check (is_system or pos_system is not null);
alter table public.export_templates drop constraint if exists export_templates_other_has_name;
alter table public.export_templates add constraint export_templates_other_has_name
  check (pos_system is distinct from 'other' or btrim(coalesce(pos_other, '')) <> '');

-- Additive to the column GRANTs from 20261010_01 (a column GRANT adds; it does
-- not replace the list).
grant insert (pos_system, pos_other) on public.export_templates to authenticated;
grant update (pos_system, pos_other) on public.export_templates to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The record.
--
--   created / updated  written by the trigger on export_templates below — never
--                      by the client, so no template save can go unrecorded,
--                      even if the phone loses signal between two requests
--   request            "my system needs something the builder can't do"
--   import_feedback    "did this file import cleanly into <POS>?" — once per
--                      stocktake, enforced by the unique index
--
-- template_snapshot is filled by the guard trigger from the real template row,
-- never taken from the client, so what James reads is what the venue saved.
-- stocktake_id is not in the brief's list and is required: "ask once per
-- stocktake" has to hold across devices, which means the database has to know
-- which stocktake an answer was about.
--
-- sample_lines: at most 5 lines and 2,000 characters. They are real stock data
-- from a venue's POS, sent to Gantry for support (see privacy.html), and five
-- lines is enough to see a file's shape.
-- ---------------------------------------------------------------------------
create table if not exists public.export_template_submissions (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organisations(id) on delete cascade default public.my_org_id(),
  template_id uuid references public.export_templates(id) on delete set null,
  stocktake_id uuid references public.stocktakes(id) on delete set null,
  kind text not null check (kind in ('created', 'updated', 'import_feedback', 'request')),
  pos_system text check (pos_system is null or public.is_known_pos(pos_system)),
  pos_other text,
  template_snapshot jsonb,
  sample_lines text check (
    sample_lines is null or (
      length(sample_lines) <= 2000
      and coalesce(array_length(regexp_split_to_array(btrim(sample_lines, E'\r\n'), E'\r?\n'), 1), 0) <= 5)),
  import_ok boolean,
  failed_lines int check (failed_lines is null or failed_lines >= 0),
  notes text check (notes is null or length(notes) <= 2000),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  created_at timestamptz not null default now(),
  emailed_at timestamptz,
  constraint export_template_submissions_other_has_name
    check (pos_system is distinct from 'other' or btrim(coalesce(pos_other, '')) <> ''),
  constraint export_template_submissions_request_names_pos
    check (kind <> 'request' or pos_system is not null),
  constraint export_template_submissions_feedback_is_complete
    check (kind <> 'import_feedback' or (import_ok is not null and stocktake_id is not null))
);

create index if not exists export_template_submissions_org_idx
  on public.export_template_submissions (org_id, created_at desc);
-- The email sweep's question: "what hasn't gone out yet?"
create index if not exists export_template_submissions_unsent_idx
  on public.export_template_submissions (org_id, created_at) where emailed_at is null;
-- Ask once per stocktake — in the database, so two phones can't both answer.
create unique index if not exists export_template_submissions_one_feedback
  on public.export_template_submissions (stocktake_id) where kind = 'import_feedback';

alter table public.export_template_submissions enable row level security;

-- Read: the whole org, so any device can tell whether a stocktake's import has
-- already been asked about. Write: owner/manager, own org, and only the two
-- kinds a person submits — created/updated come from the trigger.
drop policy if exists "read own org submissions" on public.export_template_submissions;
create policy "read own org submissions" on public.export_template_submissions
  for select to authenticated
  using (org_id = public.my_org_id());

drop policy if exists "owner manager insert submissions" on public.export_template_submissions;
create policy "owner manager insert submissions" on public.export_template_submissions
  for insert to authenticated
  with check (org_id = public.my_org_id()
              and public.my_role() in ('owner', 'manager')
              and kind in ('request', 'import_feedback'));

-- No client UPDATE or DELETE at all: this is the record. Both halves, as on
-- every table here — Supabase's default privileges grant ALL on a new table.
-- template_snapshot, created_by and emailed_at are off the INSERT grant: the
-- trigger, the column default and notify-export-template own them.
revoke insert, update, delete on public.export_template_submissions from anon, authenticated;
grant insert (org_id, template_id, stocktake_id, kind, pos_system, pos_other,
              sample_lines, import_ok, failed_lines, notes)
  on public.export_template_submissions to authenticated;

-- ---------------------------------------------------------------------------
-- 3. The guard: runs before every submission insert, client or trigger.
--
-- security definer: it reads export_templates and stocktakes to check them, and
-- a staff-only-own-stocktakes rule must not make a manager's legitimate check
-- fail. It re-states the org scoping itself instead of relying on RLS.
--
-- The 30-per-hour cap counts only what PEOPLE submit (request, feedback). The
-- created/updated rows the template trigger writes are exempt: a cap that could
-- abort a template SAVE would turn a notification limit into data loss. Emails
-- have their own cap in notify-export-template.
-- ---------------------------------------------------------------------------
create or replace function public.guard_export_template_submission()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.export_templates%rowtype;
  v_take_org uuid;
  v_recent int;
begin
  -- Never the client's to set.
  new.created_at := now();
  new.emailed_at := null;

  if new.kind in ('request', 'import_feedback') then
    select count(*) into v_recent
      from public.export_template_submissions
     where org_id = new.org_id
       and kind in ('request', 'import_feedback')
       and created_at > now() - interval '1 hour';
    if v_recent >= 30 then
      raise exception 'Too many submissions in the last hour — please try again later.';
    end if;
  end if;

  if new.template_id is not null then
    select * into t from public.export_templates
     where id = new.template_id and (is_system or org_id = new.org_id);
    if not found then
      raise exception 'Export template not found.';
    end if;
    -- What the venue actually saved, not what a client says it saved. org_id
    -- and created_by are left out: the row already carries both.
    new.template_snapshot := to_jsonb(t) - 'org_id' - 'created_by';
    if new.pos_system is null then
      new.pos_system := t.pos_system;
      new.pos_other := t.pos_other;
    end if;
  else
    new.template_snapshot := null;
  end if;

  if new.stocktake_id is not null then
    select org_id into v_take_org from public.stocktakes where id = new.stocktake_id;
    if v_take_org is null or v_take_org is distinct from new.org_id then
      raise exception 'Stocktake not found.';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists guard_export_template_submissions on public.export_template_submissions;
create trigger guard_export_template_submissions
  before insert on public.export_template_submissions
  for each row execute function public.guard_export_template_submission();

-- ---------------------------------------------------------------------------
-- 4. Every org template save records itself.
--
-- AFTER the row is written, in the same transaction: if the save commits, so
-- does the record; if the record can't be written, the save rolls back too,
-- rather than leaving a template James never hears about.
--
-- An UPDATE that changes nothing but updated_at (touch_export_templates) is not
-- an edit and writes nothing. System templates are Gantry's own and never
-- recorded here.
-- ---------------------------------------------------------------------------
create or replace function public.record_export_template_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.is_system then
    return null;
  end if;
  if tg_op = 'UPDATE' and (to_jsonb(new) - 'updated_at') = (to_jsonb(old) - 'updated_at') then
    return null;
  end if;
  insert into public.export_template_submissions (org_id, template_id, kind, pos_system, pos_other)
  values (new.org_id, new.id,
          case when tg_op = 'INSERT' then 'created' else 'updated' end,
          new.pos_system, new.pos_other);
  return null;
end $$;

drop trigger if exists record_export_template_changes on public.export_templates;
create trigger record_export_template_changes
  after insert or update on public.export_templates
  for each row execute function public.record_export_template_change();

-- ---------------------------------------------------------------------------
-- 5. Which template a stocktake's last export used.
--
-- last_export_format already holds the template's NAME; an id is what lets the
-- app look up whether that template is verified and which POS it feeds, and ask
-- "did it import cleanly?" about exactly that file. ON DELETE SET NULL: a venue
-- deleting a template must not be blocked by the stocktakes that used it.
-- ---------------------------------------------------------------------------
alter table public.stocktakes
  add column if not exists last_export_template_id uuid
    references public.export_templates(id) on delete set null;

-- Dropped and re-created rather than `create or replace` with a fourth
-- argument: a different argument list makes a SECOND function, and PostgREST
-- then refuses a three-argument call as ambiguous (PGRST203) — which is
-- exactly the call the currently deployed app.html makes on every export. With
-- the old one gone, that same call resolves here, p_template_id defaulting to
-- NULL.
drop function if exists public.record_stocktake_export(uuid, text, boolean);

create or replace function public.record_stocktake_export(
  p_stocktake_id uuid,
  p_format text,
  p_strip_leading_zero boolean,
  p_template_id uuid default null
)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_org uuid := public.my_org_id();
  v_take_org uuid;
  v_take_name text;
  v_format text := left(coalesce(btrim(p_format), 'unknown'), 40);
  v_strip boolean := coalesce(p_strip_leading_zero, false);
  v_template uuid;
  actor uuid := auth.uid();
  actor_label text;
  org_label text;
begin
  select s.org_id, s.name into v_take_org, v_take_name
    from public.stocktakes s where s.id = p_stocktake_id;

  -- Same message whether the stocktake is missing or belongs to another org, so
  -- this can't be used to probe for UUIDs.
  if v_take_org is null or v_take_org is distinct from v_org then
    raise exception 'Stocktake not found.';
  end if;

  -- Only a template this org can actually see. Anything else is stored as NULL
  -- rather than refused: the stamp is a record, and a record must never be the
  -- reason an export failed.
  select id into v_template from public.export_templates
   where id = p_template_id and (is_system or org_id = v_org);

  update public.stocktakes
     set last_exported_at = now(),
         last_export_format = v_format,
         last_export_strip_leading_zero = v_strip,
         last_export_template_id = v_template
   where id = p_stocktake_id;

  select coalesce(p.full_name, u.email, 'Unknown user') into actor_label
    from auth.users u left join public.profiles p on p.id = u.id where u.id = actor;
  select o.name into org_label from public.organisations o where o.id = v_org;

  insert into public.audit_log (org_id, org_label, actor_id, actor_label, action, entity_type, entity_id, target_label, after)
  values (v_org, org_label, actor, actor_label, 'stocktake.exported', 'stocktake',
          p_stocktake_id, v_take_name,
          jsonb_build_object('format', v_format, 'strip_leading_zero', v_strip,
                             'template_id', v_template));
end $$;

grant execute on function public.record_stocktake_export(uuid, text, boolean, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Verify:
--
--   -- 1. the POS list and constraints exist:
--   select public.is_known_pos('bepoz'), public.is_known_pos('nope');  -- t | f
--
--   -- 2. ONE record_stocktake_export, four arguments:
--   select pg_get_function_identity_arguments(oid) from pg_proc
--    where proname = 'record_stocktake_export';
--   -- => p_stocktake_id uuid, p_format text, p_strip_leading_zero boolean, p_template_id uuid
--
--   -- 3. the record — what James reads while no email provider is configured:
--   select s.created_at, o.name as org, s.kind,
--          coalesce(s.pos_other, s.pos_system) as pos,
--          s.template_snapshot->>'name' as template,
--          s.import_ok, s.failed_lines, s.notes, s.sample_lines, s.emailed_at
--     from public.export_template_submissions s
--     join public.organisations o on o.id = s.org_id
--    order by s.created_at desc limit 50;
--
--   -- 4. in the app, as owner or manager: build and save a template -> one
--   --    'created' row above with a template_snapshot; edit it -> one 'updated';
--   --    re-save with no change -> nothing new.
--
--   -- 5. a client cannot forge the record — each must fail:
--   --    POST /rest/v1/export_template_submissions {"kind":"created",...}   -> RLS
--   --    POST ... {"kind":"request","emailed_at":"2026-01-01"}              -> 42501
--   --    PATCH /rest/v1/export_template_submissions?id=eq.<id> {...}        -> 42501
--   --    a second import_feedback for the same stocktake                    -> 23505
-- ---------------------------------------------------------------------------
