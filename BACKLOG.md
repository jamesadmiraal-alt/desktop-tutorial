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

**So the work is mostly inverting that, not building status from scratch:**

1. Add a "Mark complete" action (the `⋯` actions sheet at
   [app.html:640-652](app.html#L640-L652) is the natural home, beside Export and
   Clear items), and a way back — "Reopen" — since a venue will sometimes mark
   complete too early.
2. Decide whether export should still auto-complete. Probably yes as a fallback,
   but it must not be the only route.
3. Who may complete/reopen? Staff do the counting, so staff should probably be
   able to complete. Reopening after head office has exported is closer to a
   manager action. This needs deciding, not assuming — and note `stocktakes`
   UPDATE is currently open to **all three roles** with no `my_role()` check
   ([schema.sql:703-705](schema.sql#L703-L705)), so any restriction is new RLS.
4. Add `check (status in ('in_progress', 'completed'))` while touching this — the
   column being unconstrained is a latent bug, and a status-driven workflow makes
   it a real one.
5. **Log the transition.** `log_stocktakes_change()` is delete-only, and its
   comment explicitly says the only update today is the automatic export side
   effect "not an operator decision" ([schema.sql:970-972](schema.sql#L970-L972)).
   Once completing is a deliberate act that head office relies on, that stops
   being true — "who marked this ready, and when" belongs in the activity log
   alongside the deletion trail.
6. Consider showing completed-but-not-exported distinctly from
   completed-and-exported. Head office's real question is "what can I export
   now", which is a third state the current two-way split can't express.

**Open question worth resolving first:** is "complete" per stocktake, or does head
office want a per-location or per-venue rollup ("all of Bar's counts are in")? The
answer changes whether this is a status flag or a small workflow feature.
