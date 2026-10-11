// The export engine: one template + the stored lines -> the file a POS imports.
//
// A plain global-assigning script like barcode-export.js, which it depends on
// and must be loaded AFTER. Pure: no DOM, no network, no clock — everything it
// needs arrives in `ctx` — so scripts/test-export-engine.js can run it in node
// against the exact bytes the browser loads.
//
// Replaces the two hand-written builders that used to live in app.html
// (buildStandardCsv and buildCsv). Those are kept, verbatim, inside the test
// file as the ORACLE: the engine's output for the seeded 'standard', 'bepoz'
// and 'full' templates must be byte-identical to theirs, and that test is what
// licensed deleting them from the app.
//
// What a template is: a row of public.export_templates (see schema.sql). The
// fields read here are
//
//   identifier_type      'barcode' | 'sku' | 'stockcode' | 'system_id'
//   identifier_fallback  same set, or null
//   barcode_rules        { leading_zero, pad_length, trim } — barcode-export.js
//   include_header       boolean
//   columns              [{ header, source, value? }, ...] — order is output order
//   delimiter            ',' or '\t'
//   file_extension       'csv' | 'txt'
//   file_name_pattern    e.g. 'gantry-{location}-{stocktake}-{date}-bepoz', or null
//   bom                  boolean — see below, it is load-bearing both ways
//   mode                 'generate' (this file) | 'fill' (Phase 4, not here)
//
// And ctx:
//
//   stocktakeName, locationName, dateStamp ('YYYYMMDD', venue timezone)
//   names     { barcode: name }   — org_barcodes, the in-app directory
//   products  { barcode: { sku, stockcode, system_id, name } } — the POS product
//             list (Phase 2). Absent today, so only identifier_type 'barcode'
//             can produce a non-blank identifier yet.
window.GANTRY_EXPORT_ENGINE = (function () {
  var BX = window.GANTRY_EXPORT;

  var IDENTIFIER_TYPES = { barcode: true, sku: true, stockcode: true, system_id: true };

  // Where a column's value comes from. The brief's list (identifier, quantity,
  // item name, reason, description, location, batch code, fixed) plus three the
  // Gantry CSV has always carried — and must keep carrying byte for byte:
  // the stocktake's name and the two scan timestamps.
  //
  // reason / description / batch_code have NO data behind them yet: Gantry
  // doesn't record any of the three. They exist so a template that needs the
  // column (Lightspeed K-Series has optional Reason and Description) can emit it
  // — empty — in the right position. Use 'fixed' for a constant.
  var SOURCES = {
    identifier: true, quantity: true, item_name: true, reason: true,
    description: true, location: true, batch_code: true, fixed: true,
    stocktake_name: true, first_scanned: true, last_scanned: true,
  };

  // The POS systems a venue can say a template is for. ONE source of truth for
  // the codes and their labels, restated in exactly two other places, both
  // checked by scripts/test-export-engine.js:
  //   * is_known_pos() in SQL (20261011_01), which the check constraints on
  //     export_templates.pos_system and export_template_submissions.pos_system
  //     call — so the database refuses a code this list doesn't have;
  //   * POS_LABELS in supabase/functions/notify-export-template, which names
  //     the POS in the email subject James filters on.
  // Add a POS here, there and there together, and re-run the test.
  //
  // 'other' is last on purpose, and always needs the venue to type a name — an
  // "Other" with no name tells us nothing about which system to build for.
  var KNOWN_POS = [
    { code: 'bepoz', label: 'Bepoz' },
    { code: 'hl', label: 'H&L' },
    { code: 'myob_exo', label: 'MYOB EXO' },
    { code: 'lightspeed_r', label: 'Lightspeed Retail (R-Series)' },
    { code: 'lightspeed_k', label: 'Lightspeed Restaurant (K-Series)' },
    { code: 'shopfront', label: 'Shopfront' },
    { code: 'tower', label: 'Tower Systems Retailer' },
    { code: 'swiftpos', label: 'SwiftPOS' },
    { code: 'impos', label: 'Impos' },
    { code: 'square', label: 'Square' },
    { code: 'other', label: 'Other' },
  ];

  // "Other: Fred's POS" rather than "Other" — the name typed is the information.
  function posLabel(code, other) {
    if (code === 'other') {
      var o = String(other == null ? '' : other).trim();
      return o ? 'Other: ' + o : 'Other';
    }
    for (var i = 0; i < KNOWN_POS.length; i++) if (KNOWN_POS[i].code === code) return KNOWN_POS[i].label;
    return code ? String(code) : '';
  }

  // The builder's words for each column source, kept with SOURCES so a source
  // can't be added without being named. The three Gantry doesn't record yet say
  // so — a venue choosing "Reason" must not expect it to fill.
  var SOURCE_LABELS = {
    identifier: 'Barcode',
    quantity: 'Count',
    item_name: 'Item name',
    location: 'Location',
    stocktake_name: 'Stocktake name',
    first_scanned: 'First scanned (date and time)',
    last_scanned: 'Last scanned (date and time)',
    reason: 'Reason (always blank — not recorded yet)',
    description: 'Description (always blank — not recorded yet)',
    batch_code: 'Batch code (always blank — not recorded yet)',
    fixed: 'Fixed text (same on every line)',
  };

  // The four leading-zero rules, each with the one line a bar manager needs to
  // choose between them. Codes are barcode_rules.leading_zero values; the
  // explanations are deliberately about the POS, not the algorithm.
  var LEADING_ZERO_RULES = [
    { code: 'keep', label: 'Keep barcodes exactly as scanned',
      help: 'Use this unless your POS rejects barcodes that start with 0.' },
    { code: 'strip_one', label: 'Remove one leading zero',
      help: 'For POS systems that store "0012345678905" as "012345678905". Only touches 13- and 14-digit barcodes.' },
    { code: 'strip_all', label: 'Remove all leading zeros',
      help: 'For POS systems that store barcodes as plain numbers, with no zeros at the front at all.' },
    { code: 'pad', label: 'Pad with zeros to a fixed length',
      help: 'For POS systems that always store barcodes at one length, e.g. 13 digits.' },
  ];

  // Same as app.html's qtyText(): 0.4 not 0.40, 3 not 3.00. Bepoz accepted 0.15
  // on 2026-08-20, so decimals go out as counted and are never rounded to whole
  // bottles here.
  function qtyText(v) {
    var n = Number(v);
    return String(isFinite(n) ? Number(n.toFixed(2)) : 0);
  }

  function slugify(s, fallback) {
    return String(s == null ? '' : s)
      .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || fallback;
  }

  // Comma-delimited: EXACTLY app.html's old csvEscape() — quote when the value
  // holds a comma, a double quote or a newline, and double any quotes. Not
  // "improved" to also catch \r: the byte-identity guarantee covers every
  // stocktake name anyone has already exported, and a quoting change is a byte
  // change.
  //
  // Tab-delimited: tabs and line breaks become spaces, and NOTHING is quoted.
  // TSV importers mostly don't understand CSV-style quoting at all, so a quoted
  // field arrives with literal quote marks in it — a barcode of '"9300…"' is a
  // silent no-match. Flattening is lossy only for a stocktake name with a tab in
  // it, which is lossy in a way a human can read; the alternative is lossy in a
  // way the importer can't.
  function escapeField(v, delimiter) {
    var s = (v === null || v === undefined) ? '' : String(v);
    if (delimiter === '\t') return s.replace(/[\t\r\n]+/g, ' ');
    return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  // Refuse a template that can't produce a correct file, BEFORE producing one.
  // A malformed template that "works" is how a POS ends up importing the wrong
  // column as the count — the original Colac Bepoz failure, reached by a new road.
  // Returns a list of problems; empty means usable.
  function validateTemplate(t) {
    var problems = [];
    if (!t) return ['No export template is set for this organisation.'];
    if ((t.mode || 'generate') !== 'generate') {
      problems.push('"' + (t.name || 'This template') + '" fills in a file from your POS, '
        + 'which this export cannot do yet.');
    }
    if (!IDENTIFIER_TYPES[t.identifier_type || 'barcode']) {
      problems.push('Unknown identifier type "' + t.identifier_type + '".');
    }
    if (t.identifier_fallback && !IDENTIFIER_TYPES[t.identifier_fallback]) {
      problems.push('Unknown fallback identifier type "' + t.identifier_fallback + '".');
    }
    if (t.delimiter !== ',' && t.delimiter !== '\t') {
      problems.push('Delimiter must be a comma or a tab.');
    }
    var cols = t.columns;
    if (!Array.isArray(cols) || !cols.length) {
      problems.push('The template has no columns.');
    } else {
      var hasId = false, hasQty = false;
      cols.forEach(function (c, i) {
        if (!c || !SOURCES[c.source]) {
          problems.push('Column ' + (i + 1) + ' has an unknown source "' + (c && c.source) + '".');
          return;
        }
        if (c.source === 'identifier') hasId = true;
        if (c.source === 'quantity') hasQty = true;
      });
      // Every stocktake import the brief's research found wants these two. A
      // template without them is not a stocktake import, whatever it's called.
      if (!hasId) problems.push('The template has no identifier column.');
      if (!hasQty) problems.push('The template has no quantity column.');
    }
    return problems;
  }

  // The identifier a POS matches on, for one stored line.
  //
  // 'barcode' is the barcode after the template's barcode_rules — the leading-
  // zero handling lives here and only here, so every template gets it the same
  // way. The other three come from the POS product list, looked up by the
  // rule-applied barcode first (that's the form the POS itself stores) and the
  // raw scan second.
  function identifierFor(item, type, rules, products) {
    var applied = BX.applyBarcodeRules(item.barcode, rules);
    if ((type || 'barcode') === 'barcode') return applied;
    var p = products && (products[applied] || products[item.barcode]);
    var v = p && p[type];
    return (v === null || v === undefined) ? '' : String(v).trim();
  }

  function productFor(row, rules, products) {
    if (!products) return null;
    return products[BX.applyBarcodeRules(row.barcode, rules)] || products[row.barcode] || null;
  }

  function valueFor(col, row, t, ctx) {
    switch (col.source) {
      case 'identifier': return row.identifier;
      case 'quantity': return qtyText(row.qty);
      case 'item_name': {
        // The POS's own name first — Lightspeed K-Series matches on "Stock name",
        // so it has to be the POS's spelling — then the in-app directory.
        var p = productFor(row, t.barcode_rules, ctx.products);
        if (p && p.name) return p.name;
        return (ctx.names && ctx.names[row.barcode]) || '';
      }
      case 'location': return ctx.locationName || '';
      case 'stocktake_name': return ctx.stocktakeName || '';
      case 'first_scanned': return row.first_scanned;
      case 'last_scanned': return row.last_scanned;
      case 'fixed': return col.value == null ? '' : col.value;
      default: return ''; // reason, description, batch_code: no data recorded yet
    }
  }

  // Characters no filesystem accepts, removed rather than escaped — this is a
  // name a bar manager reads in a Downloads folder.
  var FILENAME_JUNK = /[\\/:*?"<>|\u0000-\u001f]+/g;

  // {location} {stocktake} {date} {template}, slugified. Default pattern is the
  // one app.html's fileName() has always produced.
  //
  // {location} expands to NOTHING when the stocktake's own name already contains
  // it: the default name suggestTakeName() offers is "<location> – <date>", and
  // printing it twice gave gantry-cellar-cellar-…. Then empty tokens' separators
  // collapse, so "gantry--morning-count" can't happen either.
  var DEFAULT_PATTERN = 'gantry-{location}-{stocktake}-{date}';
  function fileNameFor(t, ctx) {
    var take = slugify(ctx.stocktakeName, 'stocktake');
    var loc = slugify(ctx.locationName, '');
    if (loc && take.indexOf(loc) !== -1) loc = '';
    var name = String(t.file_name_pattern || DEFAULT_PATTERN)
      .replace(/\{location\}/g, loc)
      .replace(/\{stocktake\}/g, take)
      .replace(/\{date\}/g, ctx.dateStamp || '')
      .replace(/\{template\}/g, slugify(t.name, 'export'))
      .replace(FILENAME_JUNK, '')
      .replace(/-{2,}/g, '-')
      .replace(/^[-_.\s]+|[-_.\s]+$/g, '');
    return (name || 'gantry-export') + '.' + (t.file_extension === 'txt' ? 'txt' : 'csv');
  }

  // template + stored lines + ctx -> { text, bom, fileName, mime, lineCount, blank }
  //
  // Throws (with the validation problems as the message) on a template that
  // can't produce a correct file. The caller shows that and exports nothing.
  //
  // `blank` lists the lines whose identifier came out empty — e.g. a SKU
  // template and a barcode the product list doesn't know. They are still in the
  // file (dropping a counted line silently is the one thing worse than an
  // unmatched one), and the caller decides what to say. Always empty for a
  // barcode template.
  function buildExport(t, items, ctx) {
    var problems = validateTemplate(t);
    if (problems.length) throw new Error(problems.join(' '));
    ctx = ctx || {};
    var rules = t.barcode_rules || {};
    var delimiter = t.delimiter;

    // Resolve, THEN merge, keyed on the resolved identifier: two paddings of one
    // barcode, or two barcodes that share one SKU, are one product to the POS
    // and must be one line with the counts added. Multi-device totals are
    // already one row per barcode before this (unique (stocktake_id, barcode) +
    // add_stocktake_item()), so this is the only merge left to do.
    var rows = BX.mergeItemsForExport(items, {
      keyOf: function (it) {
        var id = identifierFor(it, t.identifier_type, rules, ctx.products);
        if (id === '' && t.identifier_fallback) {
          id = identifierFor(it, t.identifier_fallback, rules, ctx.products);
        }
        return id;
      },
    });

    var lines = [];
    if (t.include_header) {
      lines.push(t.columns.map(function (c) {
        return escapeField(c.header == null ? '' : c.header, delimiter);
      }).join(delimiter));
    }
    var blank = [];
    rows.forEach(function (row) {
      if (row.identifier === '') blank.push(row);
      lines.push(t.columns.map(function (c) {
        return escapeField(valueFor(c, row, t, ctx), delimiter);
      }).join(delimiter));
    });

    return {
      // \r\n and no trailing newline: what both old builders produced, so what
      // every importer that has accepted a Gantry file has seen.
      text: lines.join('\r\n'),
      // Per template, and load-bearing in OPPOSITE directions: Excel needs the
      // byte-order mark to read the Gantry CSV's accented venue names, and the
      // same three bytes make a headerless POS file's FIRST barcode arrive as
      // "﻿9351142000085", which a strict importer silently fails to match.
      bom: t.bom === true,
      fileName: fileNameFor(t, ctx),
      mime: (t.file_extension === 'txt' ? 'text/plain' : 'text/csv') + ';charset=utf-8',
      lineCount: rows.length,
      blank: blank,
    };
  }

  // The bridge for organisations.strip_leading_zero, the org-wide toggle that
  // shipped on 2026-09-29 before templates existed. The brief says to keep it
  // working until migrated, so: when it is ON and the template says 'keep', the
  // template is treated as 'strip_one'. It never overrides a template that has
  // its own rule (strip_all, pad, or strip_one already).
  //
  // set_export_template() keeps the flag mirrored to the chosen template, so in
  // steady state this is a no-op. It matters for exactly one window: a cached
  // admin page from before this release calling set_strip_leading_zero(), which
  // must still change the next file the way it says it will.
  function withLegacyStrip(t, legacyStrip) {
    if (!t || !legacyStrip) return t;
    var rules = t.barcode_rules || {};
    if ((rules.leading_zero || 'keep') !== 'keep') return t;
    var copy = {};
    for (var k in t) if (Object.prototype.hasOwnProperty.call(t, k)) copy[k] = t[k];
    copy.barcode_rules = {};
    for (var r in rules) if (Object.prototype.hasOwnProperty.call(rules, r)) copy.barcode_rules[r] = rules[r];
    copy.barcode_rules.leading_zero = 'strip_one';
    return copy;
  }

  // The system template an org with no export_template_id gets, from its two
  // legacy columns. ONE mapping, used by app.html (to export) and admin.html (to
  // show which template is in effect), and restated in SQL in exactly one place:
  // the 20261010_01 migration's UPDATE, which pointed every existing org at the
  // same answer. It is the old exportFormat() fallback exactly — 'standard' and
  // the pre-rename 'bepoz' are the standard shape; anything else (legacy
  // 'myob'/'lightspeed', 'full') is the full CSV, the safe direction for a value
  // nobody recognises.
  function legacyTemplateCode(exportFormat, stripLeadingZero) {
    if (exportFormat === 'standard' || exportFormat === 'bepoz') {
      return stripLeadingZero ? 'bepoz' : 'standard';
    }
    return 'full';
  }

  // ---- Picker helpers -------------------------------------------------------
  //
  // The template picker exists twice: admin.html (head office, Multi-venue
  // only) and app.html's Account → Exports (every plan, so single-venue and
  // trial venues can choose too). These are the parts both need to agree on,
  // so they live once, here. Still no DOM: each page builds its own <option>s.

  // Which template is in effect for an org — the one it named, or, with no id
  // (or an id that no longer resolves), the system template its legacy columns
  // map to. Never "whatever the <select> shows": a browser shows the FIRST
  // option for a value it can't match, which is how admin.html once told a
  // Gantry-CSV org it was on the standard format.
  //
  // org: { exportTemplateId, exportFormat, stripLeadingZero }
  function effectiveTemplate(templates, org) {
    var list = templates || [];
    if (!org) return null;
    var i;
    if (org.exportTemplateId) {
      for (i = 0; i < list.length; i++) if (list[i].id === org.exportTemplateId) return list[i];
    }
    var code = legacyTemplateCode(org.exportFormat, org.stripLeadingZero);
    for (i = 0; i < list.length; i++) if (list[i].is_system && list[i].code === code) return list[i];
    return null;
  }

  // Gantry's first, then the org's own — each list in the order given (the
  // query orders by name).
  function groupTemplates(templates) {
    var list = templates || [];
    return [
      { label: 'Gantry templates', rows: list.filter(function (t) { return t.is_system; }) },
      { label: 'Your templates', rows: list.filter(function (t) { return !t.is_system; }) },
    ].filter(function (g) { return g.rows.length; });
  }

  // "unverified" in the option itself, not only in the explanation under it:
  // it has to be visible at the moment of choosing, not after.
  function templateOptionLabel(t) {
    return (t && t.name ? t.name : 'Template') + (t && !t.verified ? ' — unverified' : '');
  }

  // A fill template needs the venue's own POS file at export time, so it can't
  // be what one tap on Export produces. set_export_template() refuses it; the
  // pickers don't offer it.
  function isSelectableDefault(t) {
    return !!t && (t.mode || 'generate') === 'generate';
  }

  // The description, plus the two things that change what an operator should
  // do: not yet checked against a real import, and a POS that REPLACES its
  // counts with the file.
  function templateDetail(t) {
    if (!t) return '';
    var parts = [];
    if (t.description) parts.push(t.description);
    if (!t.verified) parts.push('Not yet checked against a real import — check the first one closely.');
    if (t.import_behaviour === 'replace') {
      parts.push('This POS replaces its counts with the file: anything not in it may be set to zero.');
    }
    return parts.join(' ');
  }

  // What set_export_template() writes into the two legacy columns, so a page
  // can mirror it locally without a reload — and so effectiveTemplate() and the
  // server agree straight after a change. Must match the SQL in
  // set_export_template(); test-export-engine.js checks both.
  function legacyMirror(t) {
    var rules = (t && t.barcode_rules) || {};
    return {
      exportFormat: (t && t.is_system && t.code === 'full') ? 'full' : 'standard',
      stripLeadingZero: (rules.leading_zero || 'keep') === 'strip_one',
    };
  }

  return {
    buildExport: buildExport,
    withLegacyStrip: withLegacyStrip,
    legacyTemplateCode: legacyTemplateCode,
    effectiveTemplate: effectiveTemplate,
    groupTemplates: groupTemplates,
    templateOptionLabel: templateOptionLabel,
    isSelectableDefault: isSelectableDefault,
    templateDetail: templateDetail,
    legacyMirror: legacyMirror,
    validateTemplate: validateTemplate,
    fileNameFor: fileNameFor,
    escapeField: escapeField,
    SOURCES: SOURCES,
    SOURCE_LABELS: SOURCE_LABELS,
    IDENTIFIER_TYPES: IDENTIFIER_TYPES,
    KNOWN_POS: KNOWN_POS,
    posLabel: posLabel,
    LEADING_ZERO_RULES: LEADING_ZERO_RULES,
  };
})();
