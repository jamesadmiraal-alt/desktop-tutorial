# Gantry backlog

Requested work that isn't started yet. Each entry records what exists already, so
planning doesn't re-derive it. Delete an entry when it ships.

---

## Shared logins bypass the seat paywall — and undermine the audit trail

**Raised 2026-08-18.** One login used on ten devices consumes **one** seat. A venue
can put a single account on every phone and never pay for a second seat.

**Mechanism, and it's by design rather than a bug:** `active_sessions.user_id` is
the PRIMARY KEY ([schema.sql](schema.sql)) — one row per *person*, not per device.
`claim_seat()` says so explicitly: if a row already exists for `auth.uid()` it
refreshes `last_seen_at` and returns true, with the comment *"Already holding a
seat (e.g. a second device…) — refresh it, don't count it twice."* That was written
for the legitimate one-person-two-devices case, and it hands over the bypass as a
side effect. Nothing is broken; the model is just wrong for the business.

**The second consequence is worse than the billing one.** The whole
dispute-protection trail shipped on 2026-08-18 attributes actions to a *user*:
"Sam Lee deleted stocktake X — 247 items". If ten people share Sam's login, that
sentence is worthless as evidence, which is the one thing it exists to be. So this
isn't only revenue leakage — it quietly devalues the audit work.

**Options:**

1. **One device per login** (recommended starting point). Keep one seat per
   person, but a login from a new device ends the previous session — the
   streaming-service model. Sharing an account stops being *useful*: ten staff on
   one login can't work at the same time, which is exactly the paywall. Costs
   nothing extra for a legitimate user and strengthens attribution. The downside
   is a real one: someone genuinely moving between a phone and a tablet gets
   logged out. The `kick-user` function and the heartbeat machinery needed for
   this already exist.
2. **Per-device seats.** Add a client-generated persistent device id and key
   `active_sessions` on it, so ten devices consume ten seats. The most literal
   reading of "concurrent users", and it bills the actual usage — but it also
   charges a single operator with two devices for two seats, which needs to be a
   deliberate pricing decision, not an accident.
3. **Detect and report only.** Log when one account is seen from several devices
   and surface it to the owner (and to you). Softest, and doesn't stop anything.

Worth noting enforcement would be *fair* here: `create-team-member` already lets
an owner create individual logins directly, with no join code and no email
round-trip, so "we share one login because setting up accounts is a hassle" isn't
true of this product.

**Not started. Needs a pricing decision before implementation** — options 1 and 2
imply different things about what a "seat" is, and the answer should be the same
one used in the plan copy and STRIPE-SETUP.md.

---

## Log exports

**Raised 2026-08-19, while shipping the three-state workflow below.** Exports are
not recorded anywhere. Now that `completed` means "an export happened", the
activity log can say the status changed but not who exported or what they took —
so a dispute about *which* numbers head office received still has no evidence
behind it, even though the deletion trail is now solid.

Would need a `stocktake.exported` audit action written from the export path,
capturing the format (Gantry / MYOB / Lightspeed), the item and unit totals at
that moment, and the actor. The row totals matter more than the file: they're what
makes a later "these aren't the numbers we sent you" answerable.

---

## ~~Explicit "Complete stocktake" action~~ — SHIPPED 2026-08-19

Shipped as the three-state workflow (`in_progress` → `ready_for_export` →
`completed`) in commit `e436cd0`. Kept below for the reasoning; delete once
you're happy it's settled.

## Explicit "Complete stocktake" action

**Requested 2026-08-18.** A venue should be able to mark a stocktake finished, so
head office knows it's ready to export rather than having to guess whether
counting is still going on.

**What already exists** — this is roughly half-built, but wired backwards:

- `stocktakes.status` is already there: `text not null default 'in_progress'`
  ([schema.sql:279](schema.sql#L279)). It is **unconstrained** — no
  `check (status in (...))` — so nothing stops a typo'd value today.
- The Home list **already splits** in-progress from completed:
  `renderHome()` filters on `status === 'completed'` into
  `#stocktake-list-inprogress` and `#stocktake-list-completed`, with
  `#completed-heading` hidden when the completed set is empty
  ([app.html:1948-1958](app.html#L1948-L1958)).
- **But the transition is automatic and inverted.** `exportWithFormat()` flips
  `status` to `'completed'` on the first successful export
  ([app.html:2411-2417](app.html#L2411-L2417)). So today *exporting* marks it
  done, whereas the request is that *marking it done* signals it's ready to
  export. Head office currently can't tell "still counting" from "finished but
  not exported" — both read as In Progress.

### The state machine (specified 2026-08-18)

Three states, not two. `ready_for_export` is the new one and is the whole point:
it's the signal head office watches for, and today it's unrepresentable — a
finished-but-unexported count looks identical to one still being counted.

| Status | Meaning |
|---|---|
| `in_progress` | Being counted. Default for a new stocktake. |
| `ready_for_export` | Venue says counting is done. **Head office's cue to export.** |
| `completed` | Export has happened. |

Transitions:

| From | To | Trigger | Logged |
|---|---|---|---|
| `in_progress` | `ready_for_export` | user marks it ready | yes |
| `ready_for_export` | `in_progress` | user reverts — more counting needed | yes |
| `ready_for_export` | `completed` | automatic, on successful export | yes |
| `completed` | `in_progress` | user reverts to make changes | yes |
| `completed` | `ready_for_export` | user reverts | yes |

Every transition is logged, including the automatic export one — head office is
going to rely on this, so "who moved it, when, and which way" needs to be as
durable as the deletion trail. Distinguish the automatic transition from a manual
one in the log (actor is the exporter either way, but the *reason* differs).

**Implementation notes**

1. Add `check (status in ('in_progress', 'ready_for_export', 'completed'))`. The
   column is unconstrained today, which is a latent bug and becomes a real one
   once a workflow depends on the value. Purely additive for existing rows — they
   already hold only `in_progress` or `completed`, so no backfill.
2. **`renderHome()` needs a third section.** Its current filter is binary —
   `status === 'completed'` versus everything else
   ([app.html:1948-1958](app.html#L1948-L1958)) — so `ready_for_export` would
   silently fall into "In Progress" and the feature would appear not to work.
   Three headings, with Ready for export most prominent: it's the one someone is
   waiting on.
3. Actions live in the `⋯` sheet ([app.html:640-652](app.html#L640-L652)),
   label depending on current status ("Mark ready for export" / "Back to in
   progress" / "Reopen").
4. Export keeps auto-completing ([app.html:2411-2417](app.html#L2411-L2417)) but
   is no longer the only route into `completed`, and must now log the transition.
5. **Log via a trigger, not the client.** `log_stocktakes_change()` is delete-only
   and its comment says the only update today is the automatic export side effect,
   "not an operator decision" ([schema.sql:970-972](schema.sql#L970-L972)) — that
   stops being true here, and the comment needs updating. A BEFORE/AFTER UPDATE
   trigger on `stocktakes` firing when `status` changes is tamper-evident in a way
   a client-side audit insert is not, and matches how every other action is
   logged.

**Still to decide**

- **Who may revert a `completed` stocktake?** This is the risky transition: head
  office has already exported, and reverting invites a second export with
  different numbers. Marking *ready* is clearly a staff action; un-completing may
  warrant owner/manager. Note `stocktakes` UPDATE is currently open to **all three
  roles** with no `my_role()` check
  ([schema.sql:703-705](schema.sql#L703-L705)), so any restriction is new RLS, and
  a column-level restriction on `status` alone is not expressible in RLS — it
  would need a trigger or an RPC.
- Should head office see *which* export produced `completed`? Exports aren't
  logged at all today, so "exported by X at Y" doesn't exist as a record.
- Per-stocktake only, or does head office also want a per-location rollup ("all
  of Bar's counts are ready")? Doesn't change the state machine, but does change
  whether anything aggregates it.
