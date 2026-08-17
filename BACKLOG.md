# Gantry backlog

Requested work that isn't started yet. Each entry records what exists already, so
planning doesn't re-derive it. Delete an entry when it ships.

---

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
