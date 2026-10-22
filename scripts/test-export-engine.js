// Tests for export-engine.js — `node scripts/test-export-engine.js`.
//
// No runner, no dependencies, same as test-barcode-export.js. Two things make
// this file load-bearing rather than decorative:
//
// 1. THE ORACLE. The builders below marked ORACLE are app.html's buildCsv(),
//    buildStandardCsv(), csvEscape(), qtyText() and fileName() exactly as they
//    stood at commit 1e4d81e, copied verbatim. They are what every venue has
//    been importing. The brief's first acceptance criterion is that the new
//    engine's Bepoz export is byte-identical to the current one; this file
//    checks that for all three seeded templates, with the strip toggle both
//    ways, on data built to hit every escaping edge. Do not "tidy" the oracle —
//    its job is to be the old code, warts included.
//
// 2. THE SEEDS. The templates are not restated here. They are parsed out of the
//    $seed$ block of the migration that inserts them, and the same block is
//    required to appear unchanged in schema.sql. So the test, the migration and
//    the rebuild script all read one piece of text.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const sandbox = { window: {} };
for (const f of ['barcode-export.js', 'export-engine.js']) {
  const file = path.join(root, f);
  vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
}
const BX = sandbox.window.GANTRY_EXPORT;
const E = sandbox.window.GANTRY_EXPORT_ENGINE;

let failures = 0, checks = 0;
function eq(actual, expected, label) {
  checks++;
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`  FAIL  ${label}\n        expected ${e}\n        actual   ${a}`);
}
function throws(fn, pattern, label) {
  checks++;
  try { fn(); } catch (e) {
    if (pattern.test(e.message)) return;
    failures++;
    console.error(`  FAIL  ${label}\n        threw the wrong thing: ${e.message}`);
    return;
  }
  failures++;
  console.error(`  FAIL  ${label}\n        did not throw`);
}

// ---------------------------------------------------------------------------
// The seeds, from the migration — and the same text in schema.sql.
// ---------------------------------------------------------------------------
function seedBlock(file) {
  const sql = fs.readFileSync(path.join(root, file), 'utf8').replace(/\r\n/g, '\n');
  // Anchored on the brackets: the comments around the block say "$seed$" too.
  const m = sql.match(/\$seed\$(\[[\s\S]*?\])\$seed\$/);
  if (!m) throw new Error('no $seed$ block in ' + file);
  return m[1];
}
const migrationSeed = seedBlock('supabase/migrations/20261010_01_export_templates.sql');
eq(seedBlock('schema.sql'), migrationSeed, 'schema.sql carries the identical $seed$ block');
const SEEDS = {};
JSON.parse(migrationSeed).forEach((t) => { SEEDS[t.code] = t; });
eq(Object.keys(SEEDS).sort(), ['bepoz', 'full', 'standard'], 'three system templates seeded');

// ---------------------------------------------------------------------------
// ORACLE — app.html at 1e4d81e, verbatim. QTY_DP and takeDateStamp are the
// only stand-ins: the constant, and a fixed date so filenames are comparable.
// ---------------------------------------------------------------------------
const QTY_DP = 2;
const FIXED_DATE = '20260929';
function takeDateStamp() { return FIXED_DATE; }
/* eslint-disable */
  function qtyNum(v) {
    var n = Number(v);
    return isFinite(n) ? n : 0;
  }
  function qtyRound(n) {
    // +Number() drops the trailing zeros toFixed leaves behind.
    return Number(qtyNum(n).toFixed(QTY_DP));
  }
  function qtyText(v) {
    return String(qtyRound(v));
  }
  function csvEscape(v) {
    v = String(v);
    return /[",\n]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;
  }
  function buildCsv(take, takeItems) {
    var rows = [['stocktake', 'barcode', 'qty', 'first_scanned', 'last_scanned']];
    takeItems.forEach(function (it) {
      rows.push([take.name, it.barcode, qtyText(it.qty), it.first_scanned, it.last_scanned]);
    });
    return rows.map(function (r) { return r.map(csvEscape).join(','); }).join('\r\n');
  }
  function buildStandardCsv(take, takeItems) {
    var rows = takeItems.map(function (it) { return [it.barcode, qtyText(it.qty)]; });
    return rows.map(function (r) { return r.map(csvEscape).join(','); }).join('\r\n');
  }
  function slugify(s, fallback) {
    return String(s == null ? '' : s)
      .toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '') || fallback;
  }
  function fileName(take, suffix) {
    var takeSlug = slugify(take && take.name, 'stocktake');
    var locSlug = slugify(take && take.locations && take.locations.name, '');
    var parts = ['gantry'];
    if (locSlug && takeSlug.indexOf(locSlug) === -1) parts.push(locSlug);
    parts.push(takeSlug);
    parts.push(takeDateStamp(take));
    if (suffix) parts.push(suffix);
    return parts.join('-') + '.csv';
  }
/* eslint-enable */
// The old doExport(), reduced to what it decided: merge with the org toggle,
// then the format's builder, BOM and filename. EXPORT_FORMATS as it was.
const OLD_FORMATS = {
  standard: { build: buildStandardCsv, suffix: 'standard', bom: false },
  full: { build: buildCsv, suffix: '', bom: true },
};
function oldExport(format, strip, take, items) {
  const fmt = OLD_FORMATS[format];
  const merged = BX.mergeItemsForExport(items, { stripLeadingZero: strip });
  return { text: fmt.build(take, merged), bom: fmt.bom, fileName: fileName(take, fmt.suffix) };
}

// What app.html now does: template (with the legacy toggle bridged) -> engine.
function newExport(template, legacyStrip, take, items) {
  const t = E.withLegacyStrip(template, legacyStrip);
  const out = E.buildExport(t, items, {
    stocktakeName: take.name,
    locationName: take.locations && take.locations.name,
    dateStamp: FIXED_DATE,
    names: {},
  });
  return { text: out.text, bom: out.bom, fileName: out.fileName };
}

// ---------------------------------------------------------------------------
// Fixtures — real Colac shapes plus every escaping edge the old code handled.
// ---------------------------------------------------------------------------
const ITEMS = [
  // Colac's two paddings of one product, and Tyrrell's 14-digit capture.
  { barcode: '0797776409853', qty: '10.00', first_scanned: '2026-09-29T02:00:00+00:00', last_scanned: '2026-09-29T02:05:00+00:00' },
  { barcode: '797776409853', qty: '1.00', first_scanned: '2026-09-29T01:00:00+00:00', last_scanned: '2026-09-29T03:00:00+00:00' },
  { barcode: '00930072700123', qty: '2.00', first_scanned: '2026-09-29T02:10:00+00:00', last_scanned: '2026-09-29T02:11:00+00:00' },
  // A 12-digit UPC-A with a real leading zero: must never be stripped.
  { barcode: '012345678905', qty: '4.00', first_scanned: '2026-09-29T02:12:00+00:00', last_scanned: '2026-09-29T02:12:00+00:00' },
  // Part bottles, numeric-as-string, binary float dust, zero.
  { barcode: '9369998094189', qty: '0.40', first_scanned: '2026-09-29T02:13:00+00:00', last_scanned: '2026-09-29T02:14:00+00:00' },
  { barcode: '9300727001235', qty: 0.30000000000000004, first_scanned: '2026-09-29T02:15:00+00:00', last_scanned: '2026-09-29T02:15:00+00:00' },
  { barcode: '95049809', qty: '0.00', first_scanned: '2026-09-29T02:16:00+00:00', last_scanned: '2026-09-29T02:16:00+00:00' },
  // Things only a QR or Code 128 produces — must be quoted exactly as before.
  { barcode: 'https://example.com/w?a=1,b=2', qty: '1.00', first_scanned: '2026-09-29T02:17:00+00:00', last_scanned: '2026-09-29T02:17:00+00:00' },
  { barcode: 'WEIRD,"CODE"', qty: '3.50', first_scanned: '2026-09-29T02:18:00+00:00', last_scanned: '2026-09-29T02:18:00+00:00' },
  { barcode: '0ABC1234567890', qty: '1.25', first_scanned: '2026-09-29T02:19:00+00:00', last_scanned: '2026-09-29T02:19:00+00:00' },
];

const TAKES = [
  // Location already in the name (suggestTakeName()'s default) — not repeated.
  { name: 'Cellar – 29/9/2026', locations: { name: 'Cellar' } },
  // Location NOT in the name — prepended. A comma and quotes in the name, which
  // the full CSV must quote.
  { name: 'Morning count, "final"', locations: { name: 'Port Adl Bar' } },
  // No location at all.
  { name: 'Stress test 2', locations: null },
];

// ---------------------------------------------------------------------------
// 1. Byte identity — the acceptance criterion.
// ---------------------------------------------------------------------------
console.log('byte identity against the old builders');

TAKES.forEach((take, ti) => {
  // Standard, toggle off: what all 6 orgs export today.
  eq(newExport(SEEDS.standard, false, take, ITEMS), oldExport('standard', false, take, ITEMS),
     `take ${ti}: 'standard' template == old standard export (toggle off)`);

  // Bepoz template == old standard export with the toggle ON — what Colac
  // would have got by ticking the box. Content AND BOM identical; only the
  // filename suffix differs, and it is meant to.
  const nb = newExport(SEEDS.bepoz, false, take, ITEMS);
  const ob = oldExport('standard', true, take, ITEMS);
  eq([nb.text, nb.bom], [ob.text, ob.bom],
     `take ${ti}: 'bepoz' template content == old standard + strip toggle`);
  eq(nb.fileName, ob.fileName.replace(/-standard\.csv$/, '-bepoz.csv'),
     `take ${ti}: 'bepoz' filename is the old one with -bepoz`);

  // The legacy toggle still works on the standard template (cached admin page).
  eq(newExport(SEEDS.standard, true, take, ITEMS), oldExport('standard', true, take, ITEMS),
     `take ${ti}: legacy toggle on 'standard' == old standard + strip`);

  // Full, both ways.
  eq(newExport(SEEDS.full, false, take, ITEMS), oldExport('full', false, take, ITEMS),
     `take ${ti}: 'full' template == old Gantry CSV (toggle off)`);
  eq(newExport(SEEDS.full, true, take, ITEMS), oldExport('full', true, take, ITEMS),
     `take ${ti}: 'full' template == old Gantry CSV (toggle on)`);
});

// Spot-check the bytes themselves, so a failure above can't hide behind both
// sides being wrong the same way.
const colacBepoz = newExport(SEEDS.bepoz, false, TAKES[0], ITEMS);
eq(colacBepoz.text.split('\r\n').slice(0, 3), ['797776409853,11', '0930072700123,2', '012345678905,4'],
   'bepoz: Colac merge (10+1), Tyrrell 14->13, 12-digit UPC-A untouched');
eq(colacBepoz.text.indexOf('\n') > 0 && colacBepoz.text.indexOf('\r\n') === colacBepoz.text.indexOf('\n') - 1,
   true, 'line endings are CRLF');
eq(/\r?\n$/.test(colacBepoz.text), false, 'no trailing newline');
eq(colacBepoz.bom, false, 'bepoz: no BOM');
eq(colacBepoz.fileName, 'gantry-cellar-29-9-2026-20260929-bepoz.csv', 'bepoz: filename');
const fullHeader = newExport(SEEDS.full, false, TAKES[1], ITEMS).text.split('\r\n')[0];
eq(fullHeader, 'stocktake,barcode,qty,first_scanned,last_scanned', 'full: header row');

// ---------------------------------------------------------------------------
// 2. Multi-device aggregation — one row per item, totalled.
// ---------------------------------------------------------------------------
console.log('aggregation');

// Three devices' worth of one product (the DB already merges identical
// barcodes; the export merges what the barcode rules make identical).
const devices = E.buildExport(SEEDS.bepoz, [
  { barcode: '0797776409853', qty: '4.00' },
  { barcode: '797776409853', qty: '5.50' },
  { barcode: '00797776409853', qty: '2.00' },
], { stocktakeName: 'x', dateStamp: FIXED_DATE });
// 14 -> 13 lands on the 13-digit form, which is distinct from the 12: one zero
// per code, one pass (see test-barcode-export.js for why that is deliberate).
eq(devices.text.split('\r\n'), ['797776409853,9.5', '0797776409853,2'],
   'bepoz: 13+12 total into one row; the 14-digit lands on 13');
eq(devices.lineCount, 2, 'lineCount counts output lines, not stored lines');

// ---------------------------------------------------------------------------
// 3. Barcode rules.
// ---------------------------------------------------------------------------
console.log('barcode rules');
const R = (code, rules) => BX.applyBarcodeRules(code, rules);
eq(R('0797776409853', { leading_zero: 'keep' }), '0797776409853', 'keep');
eq(R('0797776409853', { leading_zero: 'strip_one' }), '797776409853', 'strip_one, 13');
eq(R('012345678905', { leading_zero: 'strip_one' }), '012345678905', 'strip_one leaves 12-digit alone');
eq(R('000123', { leading_zero: 'strip_all' }), '123', 'strip_all');
eq(R('0000', { leading_zero: 'strip_all' }), '0', 'strip_all never empties a code');
eq(R('0ABC123', { leading_zero: 'strip_all' }), '0ABC123', 'strip_all refuses non-digits');
eq(R('797776409853', { leading_zero: 'pad', pad_length: 13 }), '0797776409853', 'pad to 13');
eq(R('797776409853', { leading_zero: 'pad', pad_length: 14 }), '00797776409853', 'pad to 14');
eq(R('9369998094189', { leading_zero: 'pad', pad_length: 13 }), '9369998094189', 'pad never truncates');
eq(R('797776409853', { leading_zero: 'pad', pad_length: 99 }), '0797776409853', 'nonsense pad length -> 13');
eq(R('ABC', { leading_zero: 'pad' }), 'ABC', 'pad refuses non-digits');
eq(R(' 0797776409853 ', { leading_zero: 'strip_one' }), '797776409853', 'trim on by default');
eq(R(' 0797776409853 ', { leading_zero: 'strip_one', trim: false }), ' 0797776409853 ',
   'trim off -> whitespace makes it not-all-digits -> untouched');
eq(R('0797776409853', undefined), '0797776409853', 'no rules -> keep');

// ---------------------------------------------------------------------------
// 4. Template features Phase 2 and 3 will lean on.
// ---------------------------------------------------------------------------
console.log('template features');
const base = {
  name: 'Test', identifier_type: 'barcode', barcode_rules: { leading_zero: 'keep' },
  include_header: true, delimiter: ',', file_extension: 'csv', bom: false, mode: 'generate',
  columns: [{ header: 'Barcode', source: 'identifier' }, { header: 'Count', source: 'quantity' }],
};
const one = [{ barcode: '9369998094189', qty: '2.00' }];
const ctx = { stocktakeName: 'Cellar', locationName: 'Main Bar', dateStamp: FIXED_DATE,
              names: { '9369998094189': 'Coopers Pale' } };
const T = (over) => Object.assign({}, base, over);

eq(E.buildExport(base, one, ctx).text, 'Barcode,Count\r\n9369998094189,2', 'header + body');
eq(E.buildExport(T({ include_header: false }), one, ctx).text, '9369998094189,2', 'no header');

// Tab delimiter: flattened, never quoted.
eq(E.buildExport(T({ delimiter: '\t', columns: [
  { header: 'Code', source: 'identifier' }, { header: 'Qty', source: 'quantity' },
  { header: 'Note', source: 'fixed', value: 'a\tb "c", d' }] }), one, ctx).text,
  'Code\tQty\tNote\r\n9369998094189\t2\ta b "c", d', 'tab: tabs flattened, quotes and commas left literal');

// Every source.
eq(E.buildExport(T({ include_header: false, columns: [
  { header: '', source: 'item_name' }, { header: '', source: 'location' },
  { header: '', source: 'stocktake_name' }, { header: '', source: 'reason' },
  { header: '', source: 'description' }, { header: '', source: 'batch_code' },
  { header: '', source: 'fixed', value: 'ADJ' },
  { header: '', source: 'identifier' }, { header: '', source: 'quantity' }] }), one, ctx).text,
  'Coopers Pale,Main Bar,Cellar,,,,ADJ,9369998094189,2',
  'item_name from the directory; reason/description/batch blank; fixed value');

// SKU via the product list, with barcode fallback, and SKU-level merging.
const products = {
  '9369998094189': { sku: 'CPA-375', name: 'Coopers Pale Ale 375ml' },
  '9300727001235': { sku: 'CPA-375' }, // a second barcode for the same SKU
  '797776409853': { sku: 'TYR-SEM' },  // the POS stores the stripped form
};
const skuT = T({ identifier_type: 'sku', identifier_fallback: 'barcode', include_header: false,
                 barcode_rules: { leading_zero: 'strip_one' },
                 columns: [{ header: '', source: 'identifier' }, { header: '', source: 'quantity' },
                           { header: '', source: 'item_name' }] });
const skuOut = E.buildExport(skuT, [
  { barcode: '9369998094189', qty: 2 },
  { barcode: '9300727001235', qty: 3 },
  { barcode: '0797776409853', qty: 1 },   // found via the rule-applied form
  { barcode: '5000000000001', qty: 7 },   // unknown -> falls back to barcode
], Object.assign({}, ctx, { products }));
eq(skuOut.text.split('\r\n'),
   ['CPA-375,5,Coopers Pale Ale 375ml', 'TYR-SEM,1,', '5000000000001,7,'],
   'sku: two barcodes -> one SKU line totalled; lookup by stripped form; unknown falls back');
eq(skuOut.blank.length, 0, 'fallback filled every identifier');

// No fallback: unknown lines stay, blank, each on its own line, and are reported.
const noFb = E.buildExport(Object.assign({}, skuT, { identifier_fallback: null }), [
  { barcode: '5000000000001', qty: 7 },
  { barcode: '5000000000002', qty: 9 },
], Object.assign({}, ctx, { products }));
eq(noFb.text.split('\r\n'), [',7,', ',9,'], 'unresolved lines are kept, never summed together');
eq(noFb.blank.map((r) => r.barcode), ['5000000000001', '5000000000002'], 'and both are reported');

// Filenames.
eq(E.fileNameFor(T({ file_name_pattern: '{template}_{location}_{date}', file_extension: 'txt' }), ctx),
   'test_main-bar_20260929.txt', 'custom pattern, txt extension');
eq(E.fileNameFor(T({ file_name_pattern: 'stock/{stocktake}:"x"' }), ctx), 'stockcellarx.csv',
   'characters no filesystem accepts are removed');
eq(E.fileNameFor(T({ file_name_pattern: '{location}' }), { stocktakeName: 'x' }), 'gantry-export.csv',
   'a pattern that expands to nothing still names the file');
eq(E.buildExport(T({ file_extension: 'txt' }), one, ctx).mime, 'text/plain;charset=utf-8', 'txt mime');

// ---------------------------------------------------------------------------
// 5. Refusals — a template that can't produce a correct file produces none.
// ---------------------------------------------------------------------------
console.log('refusals');
throws(() => E.buildExport(null, one, ctx), /No export template/, 'no template');
throws(() => E.buildExport(T({ mode: 'fill' }), one, ctx), /fills in a file/, 'fill mode is Phase 4');
throws(() => E.buildExport(T({ columns: [{ header: 'q', source: 'quantity' }] }), one, ctx),
       /no identifier column/, 'no identifier column');
throws(() => E.buildExport(T({ columns: [{ header: 'b', source: 'identifier' }] }), one, ctx),
       /no quantity column/, 'no quantity column');
throws(() => E.buildExport(T({ columns: [{ header: 'b', source: 'identifier' },
  { header: 'q', source: 'quantity' }, { header: 'x', source: 'price' }] }), one, ctx),
       /unknown source "price"/, 'unknown source');
throws(() => E.buildExport(T({ delimiter: ';' }), one, ctx), /comma or a tab/, 'bad delimiter');
throws(() => E.buildExport(T({ identifier_type: 'plu' }), one, ctx), /Unknown identifier type/, 'bad identifier');
eq(E.validateTemplate(SEEDS.standard).concat(E.validateTemplate(SEEDS.bepoz), E.validateTemplate(SEEDS.full)),
   [], 'every seeded template validates');

// withLegacyStrip never overrides a template's own rule, and never mutates.
const padT = T({ barcode_rules: { leading_zero: 'pad', pad_length: 13 } });
eq(E.withLegacyStrip(padT, true).barcode_rules.leading_zero, 'pad', 'legacy toggle never overrides a real rule');
const before = JSON.stringify(SEEDS.standard);
E.withLegacyStrip(SEEDS.standard, true);
eq(JSON.stringify(SEEDS.standard), before, 'legacy bridge does not mutate the template');

// ---------------------------------------------------------------------------
// 6. The legacy mapping — JS and the migration's SQL must give the same answer,
// or an org with no template exports one shape while Admin shows another.
// ---------------------------------------------------------------------------
console.log('legacy mapping');
const L = E.legacyTemplateCode;
const migSql = fs.readFileSync(path.join(root, 'supabase/migrations/20261010_01_export_templates.sql'), 'utf8');
eq(/when o\.export_format in \('standard', 'bepoz'\)\s+then case when o\.strip_leading_zero then 'bepoz' else 'standard' end\s+else 'full'/.test(migSql),
   true, "migration's UPDATE still states the mapping this test checks the JS against");
eq([L('standard', false), L('standard', true), L('bepoz', false), L('bepoz', true)],
   ['standard', 'bepoz', 'standard', 'bepoz'], "'standard' and pre-rename 'bepoz' map on the strip flag");
eq([L('full', false), L('full', true), L('myob', false), L('lightspeed', true), L(undefined, false)],
   ['full', 'full', 'full', 'full', 'full'], 'everything else is the full CSV, as the old fallback was');

// ---------------------------------------------------------------------------
// 7. Picker helpers — shared by admin.html and app.html's Account → Exports,
// so both pages agree on which template an org is on.
// ---------------------------------------------------------------------------
console.log('picker helpers');
const sysList = Object.keys(SEEDS).sort().map((c) => Object.assign({ id: 'sys-' + c, is_system: true }, SEEDS[c]));
const own = { id: 'own-1', is_system: false, name: 'Our file', verified: false, mode: 'generate',
              import_behaviour: 'replace', description: 'From a sample.' };
const fill = { id: 'own-2', is_system: false, name: 'Square fill', verified: false, mode: 'fill' };
const all = sysList.concat([own, fill]);
const eff = (org) => { const t = E.effectiveTemplate(all, org); return t && t.id; };

eq(eff({ exportTemplateId: 'own-1', exportFormat: 'full' }), 'own-1', 'an explicit id wins over legacy columns');
eq(eff({ exportTemplateId: null, exportFormat: 'standard', stripLeadingZero: false }), 'sys-standard', 'no id -> standard');
eq(eff({ exportTemplateId: null, exportFormat: 'standard', stripLeadingZero: true }), 'sys-bepoz', 'no id + flag -> bepoz');
eq(eff({ exportTemplateId: null, exportFormat: 'myob' }), 'sys-full', 'no id + legacy value -> full');
eq(eff({ exportTemplateId: 'gone', exportFormat: 'standard' }), 'sys-standard', 'a deleted id falls back, never to "first option"');
eq(E.effectiveTemplate(all, null), null, 'no org -> nothing');

eq(E.groupTemplates(all).map((g) => [g.label, g.rows.map((t) => t.id)]),
   [['Gantry templates', ['sys-bepoz', 'sys-full', 'sys-standard']], ['Your templates', ['own-1', 'own-2']]],
   'Gantry first, then the org\'s own, order preserved');
eq(E.groupTemplates(sysList).length, 1, 'no empty "Your templates" group');
eq([E.templateOptionLabel(SEEDS.bepoz), E.templateOptionLabel(own)], ['Bepoz', 'Our file — unverified'],
   'unverified is in the option label itself');
eq([E.isSelectableDefault(own), E.isSelectableDefault(fill)], [true, false], 'fill templates cannot be the default');
eq(E.templateDetail(own),
   'From a sample. Not yet checked against a real import — check the first one closely. '
   + 'This POS replaces its counts with the file: anything not in it may be set to zero.',
   'detail: description, then unverified, then replace');
eq(/Colac|Port Adelaide|20\d\d-\d\d-\d\d/.test(Object.keys(SEEDS).map((c) => SEEDS[c].name + ' ' + SEEDS[c].description).join(' ')),
   false, 'system template names/descriptions carry no customer names or dates — every org reads them');

// legacyMirror must say what set_export_template() writes.
eq(/export_format = case when t\.is_system and t\.code = 'full' then 'full' else 'standard' end/.test(migSql)
   && /strip_leading_zero = coalesce\(t\.barcode_rules->>'leading_zero', 'keep'\) = 'strip_one'/.test(migSql),
   true, "set_export_template() still writes the mirror legacyMirror() reproduces");
eq([E.legacyMirror(SEEDS.standard), E.legacyMirror(SEEDS.bepoz), E.legacyMirror(Object.assign({ is_system: true }, SEEDS.full))],
   [{ exportFormat: 'standard', stripLeadingZero: false }, { exportFormat: 'standard', stripLeadingZero: true },
    { exportFormat: 'full', stripLeadingZero: false }], 'mirror per system template');
eq(E.legacyMirror(Object.assign({}, own, { barcode_rules: { leading_zero: 'strip_all' } })),
   { exportFormat: 'standard', stripLeadingZero: false }, 'custom template: standard shape; only strip_one sets the flag');
// And the round trip: whatever a pick mirrors, an org with that mirror and no id
// is shown the same system template.
['standard', 'bepoz', 'full'].forEach((c) => {
  const t = sysList.find((x) => x.code === c);
  const m = E.legacyMirror(t);
  eq(eff({ exportTemplateId: null, exportFormat: m.exportFormat, stripLeadingZero: m.stripLeadingZero }), t.id,
     `round trip: picking ${c} and losing the id still resolves to ${c}`);
});

// ---------------------------------------------------------------------------
// 8. KNOWN_POS — one list, restated in SQL (is_known_pos) and checked here.
// ---------------------------------------------------------------------------
console.log('KNOWN_POS');
const posCodes = E.KNOWN_POS.map((p) => p.code);
eq(posCodes, ['bepoz', 'hl', 'myob_exo', 'lightspeed_r', 'lightspeed_k', 'shopfront', 'tower',
              'swiftpos', 'impos', 'square', 'other'], 'the agreed list, in order, Other last');
eq(new Set(posCodes).size, posCodes.length, 'no duplicate codes');
eq(E.KNOWN_POS.every((p) => p.label && p.label.trim()), true, 'every code has a label');
function sqlPosCodes(file) {
  const sql = fs.readFileSync(path.join(root, file), 'utf8');
  const m = sql.match(/function public\.is_known_pos\(p text\)[\s\S]*?select p in \(([\s\S]*?)\)/);
  if (!m) throw new Error('is_known_pos not found in ' + file);
  return m[1].match(/'([^']+)'/g).map((q) => q.slice(1, -1));
}
eq(sqlPosCodes('supabase/migrations/20261011_01_export_template_builder.sql'), posCodes,
   'is_known_pos() in the migration lists exactly KNOWN_POS');
eq(sqlPosCodes('schema.sql'), posCodes, 'is_known_pos() in schema.sql lists exactly KNOWN_POS');
// And the edge function's copy — it names the POS in the subject James filters on.
const fnSrc = fs.readFileSync(path.join(root, 'supabase/functions/notify-export-template/index.ts'), 'utf8');
const fnLabels = fnSrc.match(/const POS_LABELS: Record<string, string> = \{([\s\S]*?)\};/);
eq(fnLabels && Array.from(fnLabels[1].matchAll(/^\s*(\w+): "([^"]*)",/gm)).map((m) => ({ code: m[1], label: m[2] })),
   E.KNOWN_POS.map((p) => ({ code: p.code, label: p.label })),
   'notify-export-template POS_LABELS == KNOWN_POS, codes and labels');
eq([E.posLabel('hl'), E.posLabel('other', "  Fred's Stock  "), E.posLabel('other', ''), E.posLabel('nope')],
   ['H&L', "Other: Fred's Stock", 'Other', 'nope'], 'posLabel: label, Other with its name, unknown passes through');
eq(Object.keys(E.SOURCE_LABELS).sort(), Object.keys(E.SOURCES).sort(), 'every column source has a builder label');
eq(E.LEADING_ZERO_RULES.map((r) => r.code), ['keep', 'strip_one', 'strip_all', 'pad'],
   'the four zero rules, each the builder offers');
eq(E.LEADING_ZERO_RULES.every((r) => r.help && r.label), true, 'each rule has a plain-English line');

// ---------------------------------------------------------------------------
// 9. Templates shaped the way the builder makes them, through buildExport.
// ---------------------------------------------------------------------------
console.log('builder-built templates');
// What the builder saves: barcode identifier only (Phase 2 adds the others),
// a POS, and whatever the venue chose for the rest.
const built = (over) => Object.assign({
  name: 'Our POS file', pos_system: 'swiftpos', identifier_type: 'barcode', identifier_fallback: null,
  barcode_rules: { leading_zero: 'keep', trim: true }, include_header: true,
  columns: [{ header: 'Barcode', source: 'identifier' }, { header: 'Qty', source: 'quantity' }],
  delimiter: ',', file_extension: 'csv', file_name_pattern: null, bom: false,
  import_behaviour: null, mode: 'generate',
}, over);
const lines = [
  { barcode: '0797776409853', qty: '10.00' },
  { barcode: '797776409853', qty: '1.00' },
  { barcode: '00930072700123', qty: '2.00' },
  { barcode: '95049809', qty: '0.50' },
];
const bctx = { stocktakeName: 'Cellar', locationName: 'Bar', dateStamp: FIXED_DATE };
const body = (t) => E.buildExport(t, lines, bctx).text.split('\r\n').slice(t.include_header ? 1 : 0);

eq(E.validateTemplate(built()), [], 'a builder template validates');
eq(body(built()), ['0797776409853,10', '797776409853,1', '00930072700123,2', '95049809,0.5'], 'keep: as scanned');
eq(body(built({ barcode_rules: { leading_zero: 'strip_one' } })),
   ['797776409853,11', '0930072700123,2', '95049809,0.5'], 'strip_one: 13+12 merged, 14->13, 8 untouched');
eq(body(built({ barcode_rules: { leading_zero: 'strip_all' } })),
   ['797776409853,11', '930072700123,2', '95049809,0.5'], 'strip_all: every zero gone, then merged');
eq(body(built({ barcode_rules: { leading_zero: 'pad', pad_length: 14 } })),
   ['00797776409853,11', '00930072700123,2', '00000095049809,0.5'], 'pad to 14: all paddings converge');
eq(E.buildExport(built({ delimiter: '\t' }), lines, bctx).text.split('\r\n')[0], 'Barcode\tQty', 'tab header');
eq(body(built({ delimiter: '\t' }))[0], '0797776409853\t10', 'tab body');
eq([E.buildExport(built({ bom: true }), lines, bctx).bom, E.buildExport(built(), lines, bctx).bom], [true, false],
   'BOM on and off follow the template');
eq(E.buildExport(built({ file_extension: 'txt', file_name_pattern: '{template}-{date}' }), lines, bctx).fileName,
   'our-pos-file-20260929.txt', 'pattern and extension');
eq(E.buildExport(built({ columns: [{ header: 'Code', source: 'identifier' }, { header: 'Count', source: 'quantity' },
  { header: 'Store', source: 'fixed', value: 'PORT ADL' }] }), lines, bctx).text.split('\r\n')[1],
   '0797776409853,10,PORT ADL', 'fixed value column');

// P8 (22 Oct): two exports of one take through different templates must not
// share a filename. Only system 'full' keeps the bare default.
console.log('file names: one take, five templates');
const sys = (code) => Object.assign({ is_system: true }, SEEDS[code]);
const names5 = [
  E.fileNameFor(sys('full'), ctx), E.fileNameFor(sys('standard'), ctx), E.fileNameFor(sys('bepoz'), ctx),
  E.fileNameFor(T({ name: 'Our POS', file_name_pattern: null }), ctx),
  E.fileNameFor(T({ name: 'Back bar', file_name_pattern: '' }), ctx),
];
eq(new Set(names5).size, 5, 'full, standard, bepoz and two blank custom patterns: 5 distinct names');
eq(names5[0], 'gantry-main-bar-cellar-' + FIXED_DATE + '.csv', 'full keeps its old name');
eq(names5[3], 'gantry-main-bar-cellar-' + FIXED_DATE + '-our-pos.csv', 'blank custom pattern ends with the template name');

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures) {
  console.error(`${failures} FAILED`);
  process.exit(1);
}
