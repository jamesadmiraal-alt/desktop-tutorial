// Shared activity-log rendering for admin.html and app.html's Team view.
//
// A plain global-assigning script, same convention as config.js — there is no
// build step and no module system here. Loaded before the page's own <script>.
//
// This lives in its own file rather than being duplicated because BOTH surfaces
// now render the log: admin.html (multi-venue owners/managers) and app.html's
// #team-view (single-venue owners/managers, who previously had no way to see it
// at all). A copy-pasted 25-entry map would drift the moment one file gained an
// action the other didn't, and a missing entry degrades to a raw
// "<actor> stocktake_items.qty_reduced" line in front of a customer.
//
// Every sentence must tolerate the jsonb keys it reads being ABSENT. Audit rows
// are historical and immutable, so rows written before a field existed will
// never gain it — describe() must not produce "undefined items" for them.
window.GANTRY_AUDIT = (function () {
  function plural(n, word) {
    return n + ' ' + word + (n === 1 ? '' : 's');
  }

  // One sentence per row, built from `action` — not a generic diff viewer.
  var SENTENCES = {
    'venue.created': function (r) { return r.actor_label + ' added venue "' + r.target_label + '"'; },
    'venue.renamed': function (r) { return r.actor_label + ' renamed venue "' + r.before.name + '" to "' + r.after.name + '"'; },
    'venue.removed': function (r) { return r.actor_label + ' removed venue "' + r.target_label + '"'; },
    'location.created': function (r) { return r.actor_label + ' added location "' + r.target_label + '"'; },
    'location.renamed': function (r) { return r.actor_label + ' renamed location "' + r.before.name + '" to "' + r.after.name + '"'; },
    'location.moved': function (r) { return r.actor_label + ' moved location "' + r.target_label + '" to a different venue'; },
    'location.removed': function (r) { return r.actor_label + ' removed location "' + r.target_label + '"'; },
    'membership.role_changed': function (r) { return r.actor_label + ' changed ' + r.target_label + '’s role from ' + r.before.role + ' to ' + r.after.role; },
    'membership.removed': function (r) { return r.actor_label + ' removed ' + r.target_label + ' from the organisation'; },
    'membership.added_by_owner': function (r) { return r.actor_label + ' added ' + r.target_label + ' to the team as ' + (r.after.role === 'manager' ? 'Manager' : 'Staff'); },
    'membership.updated_by_owner': function (r) { return r.actor_label + ' renamed ' + (r.before.full_name || 'a team member') + ' to "' + r.after.full_name + '"'; },
    'membership.password_reset_by_owner': function (r) { return r.actor_label + ' reset ' + r.target_label + '’s password'; },
    'membership.force_logged_out_by_owner': function (r) { return r.actor_label + ' logged out ' + r.target_label; },
    'membership.left_voluntarily': function (r) { return r.target_label + ' left the organisation (account deleted)'; },
    // Written by record_seat_denial() on EVERY denial, not just the ones that
    // triggered an email — the owner reviewing this later should be able to see
    // how often people were actually locked out, which the throttled email
    // can't tell them.
    // Written by claim_seat() when a login is moved to a different device. One of
    // these is ordinary (someone swapped phone for tablet); a run of them on the
    // same account is the signature of a shared login being passed around, which
    // is otherwise invisible.
    'session.taken_over': function (r) {
      return r.target_label + ' signed in on a different device, signing out the previous one';
    },
    'seat.denied': function (r) {
      var a = r.after || {};
      if (typeof a.seats_purchased !== 'number') {
        return r.target_label + ' was blocked from logging in — no seats free';
      }
      if (a.seats_purchased === 0) {
        return r.target_label + ' was blocked from logging in — no seats purchased';
      }
      return r.target_label + ' was blocked from logging in — all '
        + plural(a.seats_purchased, 'seat') + ' in use';
    },

    // The stocktake_* sentences surface counts wherever they exist, because the
    // count is what makes an entry usable in a dispute: "deleted Friday Bar
    // Count" is an assertion, "deleted Friday Bar Count — 247 items, 1032
    // units" is evidence. Each falls back to the old count-free wording for
    // rows written before the counts were captured.
    'stocktake.deleted': function (r) {
      var n = r.before && r.before.items_deleted;
      if (typeof n !== 'number') return r.actor_label + ' deleted stocktake "' + r.target_label + '"';
      return r.actor_label + ' deleted stocktake "' + r.target_label + '" — ' + plural(n, 'item')
        + ', ' + r.before.units_deleted + ' units';
    },
    // Written by set_stocktake_status(). `reason` separates a deliberate move
    // from the automatic one an export makes, which is the difference between
    // "the venue says this is done" and "head office took the data" — head
    // office relies on the first, so the log has to distinguish them.
    'stocktake.status_changed': function (r) {
      var to = r.after && r.after.status;
      var reason = r.after && r.after.reason;
      if (reason === 'export') {
        return r.actor_label + ' exported "' + r.target_label + '"';
      }
      if (to === 'ready_for_export') {
        return r.actor_label + ' marked "' + r.target_label + '" ready for export';
      }
      if (to === 'in_progress') {
        return r.actor_label + ' put "' + r.target_label + '" back to in progress';
      }
      if (to === 'completed') {
        return r.actor_label + ' marked "' + r.target_label + '" completed';
      }
      return r.actor_label + ' changed the status of "' + r.target_label + '"';
    },
    'stocktake_items.cleared': function (r) {
      var n = r.before && r.before.items_cleared;
      if (typeof n !== 'number') return r.actor_label + ' cleared all items from "' + r.target_label + '"';
      return r.actor_label + ' cleared ' + plural(n, 'item')
        + (typeof r.before.units_cleared === 'number' ? ' (' + r.before.units_cleared + ' units)' : '')
        + ' from "' + r.target_label + '"';
    },
    'stocktake_items.deleted': function (r) {
      var b = r.before || {};
      if (typeof b.items_deleted !== 'number') {
        return r.actor_label + ' removed items from "' + r.target_label + '"';
      }
      // A single removal names the actual barcode — that specificity is the
      // whole value. A batch stays summarised so one action can't flood the list.
      var one = (b.items_deleted === 1 && b.items && b.items[0]) ? b.items[0] : null;
      var what = one ? '“' + one.barcode + '” ×' + one.qty
                     : plural(b.items_deleted, 'item')
                       + (typeof b.units_deleted === 'number' ? ' (' + b.units_deleted + ' units)' : '');
      return r.actor_label + ' removed ' + what + ' from "' + r.target_label + '"';
    },
    'stocktake_items.qty_reduced': function (r) {
      var b = r.before || {};
      if (typeof b.lines_reduced !== 'number') {
        return r.actor_label + ' reduced quantities in "' + r.target_label + '"';
      }
      return r.actor_label + ' reduced ' + plural(b.lines_reduced, 'line') + ' in "' + r.target_label
        + '" by ' + b.units_removed + ' units';
    },

    'organisation.name_changed': function (r) { return r.actor_label + ' renamed the organisation from "' + r.before.name + '" to "' + r.after.name + '"'; },
    'organisation.logo_changed': function (r) { return r.actor_label + ' changed the organisation logo'; },
    'organisation.export_format_changed': function (r) { return r.actor_label + ' changed the export format from ' + r.before.export_format + ' to ' + r.after.export_format; },
    'organisation.country_changed': function (r) { return r.actor_label + ' changed the billing country from ' + r.before.country + ' to ' + r.after.country; },
    'organisation.join_code_changed': function (r) { return r.actor_label + ' rotated the join code'; },
    // Written explicitly by the set-seat-count Edge Function, not by a trigger:
    // it writes with the service role, so auth.uid() is null and every audit
    // trigger no-ops. Seat changes cost real money, so they need to be in here.
    'organisation.seats_changed': function (r) {
      var b = r.before && r.before.concurrent_seats;
      var a = r.after && r.after.concurrent_seats;
      if (typeof a !== 'number' || typeof b !== 'number') {
        return r.actor_label + ' changed the concurrent seat count';
      }
      var d = Math.abs(a - b);
      return r.actor_label + (a > b ? ' added ' : ' removed ') + plural(d, 'concurrent seat')
        + ' (' + b + ' → ' + a + ')';
    },
    'organisation.heartbeat_interval_changed': function (r) { return r.actor_label + ' changed the check-in frequency from ' + r.before.heartbeat_interval_seconds + 's to ' + r.after.heartbeat_interval_seconds + 's'; },
    'organisation.dissolved': function (r) { return r.actor_label + ' deleted their account, dissolving the organisation'; }
  };

  // Falls back to a plain "<actor> <action>" so an action added server-side
  // before the client knows about it still shows up rather than vanishing —
  // an unrecognised entry is far better than a silently dropped one when the
  // list is meant to be a complete record. Also guards a throwing sentence
  // (e.g. a row whose `before` is null) for the same reason.
  function describe(r) {
    var fn = SENTENCES[r.action];
    if (!fn) return r.actor_label + ' ' + r.action;
    try { return fn(r); } catch (e) { return r.actor_label + ' ' + r.action; }
  }

  // Shared renderer. Both callers use the same .audit-row / .msg / .when
  // markup and set textContent, never innerHTML — target_label is
  // operator-supplied (stocktake and venue names), so it must never be parsed
  // as HTML.
  function render(listEl, rows, emptyText) {
    listEl.innerHTML = '';
    if (!rows || !rows.length) {
      var empty = document.createElement('div');
      empty.className = 'audit-empty';
      empty.textContent = emptyText || 'No activity yet.';
      listEl.appendChild(empty);
      return;
    }
    rows.forEach(function (r) {
      var row = document.createElement('div');
      row.className = 'audit-row';
      var msg = document.createElement('div');
      msg.className = 'msg';
      msg.textContent = describe(r);
      var when = document.createElement('div');
      when.className = 'when';
      when.textContent = new Date(r.created_at).toLocaleString();
      row.appendChild(msg); row.appendChild(when);
      listEl.appendChild(row);
    });
  }

  return { plural: plural, SENTENCES: SENTENCES, describe: describe, render: render };
})();
