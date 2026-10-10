// Export-time barcode normalisation, shared and testable.
//
// A plain global-assigning script, same convention as config.js and
// audit-sentences.js — there is no build step and no module system here. Loaded
// before app.html's own <script>. It is also loadable by node (see
// scripts/test-barcode-export.js), which is the whole reason it is a file rather
// than two more functions inside app.html: the rules below are arithmetic on
// somebody's stock data and they need tests that don't involve a browser.
//
// ---------------------------------------------------------------------------
// WHY THIS EXISTS — Colac Port Adelaide, 2026-09-29
// ---------------------------------------------------------------------------
// The first live count (~600 lines) imported into Bepoz with about 50 lines
// unmatched. Most were products Bepoz genuinely didn't have set up. The rest
// were a leading zero:
//
//   * the same product came back as "0797776409853" from one phone and
//     "797776409853" from another, so Gantry held TWO lines for one product and
//     Bepoz matched neither reliably — it holds "797776409853";
//   * Tyrrell's Semillon came back with "00" in front where Bepoz holds a
//     single "0".
//
// In both cases removing exactly ONE leading zero produces the barcode the POS
// holds. That is not a coincidence: it is the GTIN family. The same printed
// symbol can legitimately be reported as UPC-A (12 digits), as EAN-13 (the same
// digits zero-padded to 13), or as GTIN-14 (padded again). Which one you get
// depends on the decoder, and Gantry runs two — the platform's native
// BarcodeDetector on Android Chrome, the vendored zxing-wasm ponyfill everywhere
// else (see makeDetector() in app.html). A venue counting with a mix of phones
// therefore gets a mix of paddings for one bottle, and no amount of care at the
// scanner changes that.
//
// GANTRY DOES NOT PAD. Nothing in this repo has ever added or removed a digit —
// the scan path is String(rawValue).trim() and the columns are `text`. The
// inconsistency arrives already decoded, which is exactly why the fix belongs
// here, at the boundary where the file is built for someone else's importer,
// and NOT at capture:
//
//   * what was scanned is evidence. A count is a claim about a shelf at a point
//     in time, and rewriting the digits on the way in would destroy the only
//     record of what the camera actually read;
//   * the right answer is per-POS, not universal. Bepoz wants the zero gone;
//     the next importer may insist on GTIN-13 with it. An org setting can be
//     changed, a rewritten row cannot;
//   * it must be reversible. Turn the setting off and the next export is byte
//     for byte what it would have been before any of this existed.
//
// So: stored raw, normalised on export. Nothing in this file writes anything.
window.GANTRY_EXPORT = (function () {
  // The two lengths a stripped leading zero can legitimately appear at.
  //
  // 13: a UPC-A (12) reported as EAN-13, which is a zero followed by the 12.
  // 14: the GTIN-14 form of either, which pads once more — Tyrrell's case.
  //
  // 12 is deliberately NOT here, and this is the load-bearing part of the rule.
  // A 12-digit code beginning with zero is a real UPC-A whose first digit is a
  // zero (number system 0 — most US groceries), not a padded anything. Stripping
  // it would corrupt a barcode that was already correct, turning a matched line
  // into an unmatched one: the exact failure this file exists to stop, caused by
  // the fix instead of the bug.
  //
  // 8 is absent for the same reason (EAN-8/UPC-E are their own thing), as is
  // anything longer than 14 — nothing retail is, and isPlausibleBarcode() in
  // app.html rejects an all-digit string over 18 as two scans glued together.
  var STRIPPABLE_LENGTHS = { 13: true, 14: true };

  // Remove exactly ONE leading zero, and only from a code that can have gained
  // one. Pure: same input, same output, no clock, no globals, no I/O.
  //
  // Every guard is a refusal to touch data we can't prove is padded:
  //   * setting off        -> unchanged (the default, and the whole opt-out)
  //   * not all digits     -> unchanged. A QR payload is normally a URL and
  //                          alphanumeric Code 128/39 exist; "0ABC..." keeps its
  //                          zero because we have no idea what it means. This is
  //                          the same digits-only reasoning as
  //                          isPlausibleBarcode(), where a plain length test
  //                          silently broke QR decoding once already.
  //   * not 13 or 14 long  -> unchanged (see STRIPPABLE_LENGTHS)
  //   * no leading zero    -> unchanged
  //
  // ONE zero, never a loop. "00123456789012" is 14 -> 13 and stops there, which
  // is what Bepoz holds. A while-loop would strip both and produce a 12-digit
  // code the POS has never heard of — silently, in a file nobody reads before
  // importing.
  //
  // The honest limitation of that, worth knowing before someone reports it as a
  // bug: the paddings do not all converge. A 14-digit capture lands on 13, a
  // 13-digit capture lands on 12, so one product scanned in both forms still
  // exports as two lines — one of which matches. It cannot be otherwise from the
  // digits alone: Bepoz at Colac held a 12-digit code for one product and a
  // 13-digit code for another, so "the POS form" is not a function of the
  // barcode. One zero off what was scanned is what the evidence supports.
  function normaliseBarcodeForExport(code, opts) {
    var raw = (code === null || code === undefined) ? '' : String(code);
    if (!opts || !opts.stripLeadingZero) return raw;
    if (!/^[0-9]+$/.test(raw)) return raw;
    if (!STRIPPABLE_LENGTHS[raw.length]) return raw;
    if (raw.charAt(0) !== '0') return raw;
    return raw.slice(1);
  }

  // The template-driven form of the rule above (export_templates.barcode_rules).
  //
  //   { leading_zero: 'keep' | 'strip_one' | 'strip_all' | 'pad',
  //     pad_length:   8..14   (only for 'pad'; default 13),
  //     trim:         true    (default) }
  //
  // 'strip_one' IS normaliseBarcodeForExport() — not a reimplementation of it —
  // so the 13/14-digit guard and the one-zero-never-a-loop rule hold for every
  // template that asks for it. The Bepoz system template uses it, and the
  // byte-identity test in scripts/test-export-engine.js depends on that.
  //
  // 'strip_all' and 'pad' are deliberately NEVER a default. Both exist because
  // some POS really do store barcodes as integers (no zeros at all) or as fixed
  // GTIN-13; both are only correct for a POS known to want them, which is why
  // they are a template choice and not an org-wide switch. Both refuse any code
  // that isn't all digits, for the same QR/Code-128 reason as above.
  //
  // trim defaults ON and is a no-op on real data — add_stocktake_item() already
  // btrim()s every barcode it stores. It is here for the custom templates of
  // Phase 3, whose identifiers may come from an uploaded POS file.
  function applyBarcodeRules(code, rules) {
    var raw = (code === null || code === undefined) ? '' : String(code);
    var r = rules || {};
    if (r.trim !== false) raw = raw.trim();
    var lz = r.leading_zero || 'keep';
    if (lz === 'strip_one') return normaliseBarcodeForExport(raw, { stripLeadingZero: true });
    if (!/^[0-9]+$/.test(raw)) return raw;
    if (lz === 'strip_all') {
      // Keep one digit: "0000" is a code someone scanned, and an empty
      // identifier would be a line nobody can match OR trace.
      var t = raw.replace(/^0+/, '');
      return t === '' ? '0' : t;
    }
    if (lz === 'pad') {
      var len = Number(r.pad_length);
      if (!(len >= 8 && len <= 14)) len = 13;
      while (raw.length < len) raw = '0' + raw;
      return raw;
    }
    return raw;
  }

  // Local qty helpers, matching qtyNum()/qtyRound() in app.html and kept local
  // for the same reason audit-sentences.js keeps its own units(): this file has
  // no dependency on the page.
  //
  // Number() on the way in is not optional. qty is numeric(12,2) in Postgres and
  // arrives from PostgREST as a STRING ("0.40"), so `"0.40" + "1"` would be
  // "0.401" — a merge that silently invents stock. QTY_DP=2 rounding on the way
  // out is the other half: 0.1 + 0.2 is 0.30000000000000004 in binary floats,
  // and that reaching a CSV would undermine confidence in every other number
  // in it.
  var QTY_DP = 2;
  function qtyNum(v) {
    var n = Number(v);
    return isFinite(n) ? n : 0;
  }
  function qtyRound(v) {
    return Number(qtyNum(v).toFixed(QTY_DP));
  }

  // Timestamp comparison that tolerates a missing or unparseable value, because
  // merged rows are built from whatever the row actually held.
  function ms(v) {
    var t = v ? new Date(v).getTime() : NaN;
    return isFinite(t) ? t : null;
  }

  // Normalise, then merge — in that order, and the order is the point.
  //
  // stocktake_items has `unique (stocktake_id, barcode)`, so the stored rows are
  // already one per barcode and the CSV builders were free to map 1:1. Stripping
  // a zero breaks that guarantee: "0797776409853" and "797776409853" are two
  // stored lines that become ONE product on the way out. Exporting them
  // unmerged would hand Bepoz the same barcode twice with two different counts,
  // and which one survives is the importer's business — one of the two counts
  // would quietly vanish.
  //
  // So the same product is one line, with the quantities added. 10 + 1 = 11
  // bottles, which is what is actually on the shelf.
  //
  // Called on EVERY export, whether or not the setting is on. With it off no two
  // rows can collide (the unique constraint), so this is an identity pass that
  // exists so there is only one export path to reason about — not two.
  //
  // first_scanned/last_scanned are min/max across the merged rows rather than
  // the first row's, because they go into the Gantry CSV as the window in which
  // that product was counted. Taking one row's pair would report a narrower
  // window than actually happened.
  //
  // Order is first-appearance, so a file stays in the order the count produced
  // and a re-export with the setting flipped is diffable against the last one.
  function mergeItemsForExport(items, opts) {
    var keyOf = (opts && typeof opts.keyOf === 'function') ? opts.keyOf : null;
    var out = [];
    var seen = {};
    (items || []).forEach(function (it) {
      if (!it) return;
      // opts.keyOf is the export engine's hook: once the identifier can be a SKU
      // or a stock code, two DIFFERENT barcodes that resolve to the same SKU are
      // one product in the POS and must be one line, so the merge key has to be
      // the resolved identifier rather than the barcode. Without keyOf this is
      // exactly the original barcode-keyed merge.
      var code = keyOf ? keyOf(it) : normaliseBarcodeForExport(it.barcode, opts);
      // '#' prefix: a bare barcode as an object key is user data landing in a
      // namespace that already contains "constructor" and "__proto__". Numeric
      // barcodes make that unlikely rather than impossible, and unlikely is not
      // a property worth relying on.
      var key = '#' + code;
      // A BLANK identifier is never a merge key. Under keyOf, "blank" means the
      // product list had no SKU for this barcode — and every such line sharing
      // the key "" would collapse into one row whose quantity is the sum of
      // unrelated products. Each stays its own line, so the match check can
      // name every one of them.
      var unkeyed = keyOf && code === '';
      var prev = unkeyed ? null : seen[key];
      if (!prev) {
        // A copy, never the caller's row: the stored objects are also what the
        // Home card's snapshot reads, and mutating them would make the screen
        // agree with the file by corrupting the screen.
        var row = {};
        for (var k in it) {
          if (Object.prototype.hasOwnProperty.call(it, k)) row[k] = it[k];
        }
        // With keyOf the raw barcode is kept (the identifier lives in
        // row.identifier), so a template can still print both.
        if (keyOf) row.identifier = code; else row.barcode = code;
        row.qty = qtyRound(it.qty);
        if (!unkeyed) seen[key] = row;
        out.push(row);
        return;
      }
      prev.qty = qtyRound(qtyNum(prev.qty) + qtyNum(it.qty));
      var first = ms(it.first_scanned), prevFirst = ms(prev.first_scanned);
      if (first !== null && (prevFirst === null || first < prevFirst)) prev.first_scanned = it.first_scanned;
      var last = ms(it.last_scanned), prevLast = ms(prev.last_scanned);
      if (last !== null && (prevLast === null || last > prevLast)) prev.last_scanned = it.last_scanned;
    });
    return out;
  }

  return {
    normaliseBarcodeForExport: normaliseBarcodeForExport,
    applyBarcodeRules: applyBarcodeRules,
    mergeItemsForExport: mergeItemsForExport,
    STRIPPABLE_LENGTHS: STRIPPABLE_LENGTHS,
  };
})();
