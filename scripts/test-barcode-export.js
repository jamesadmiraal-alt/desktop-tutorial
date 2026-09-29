// Tests for barcode-export.js — `node scripts/test-barcode-export.js`.
//
// There is no build step, no test runner and no node_modules for the web app
// (the one package.json here is the Capacitor shell), so this is deliberately a
// plain script with a hand-rolled assert: it must keep working on any machine
// with node and nothing else installed.
//
// barcode-export.js assigns to `window`, exactly like config.js and
// audit-sentences.js. Rather than change that convention for the test's benefit,
// the test provides a `window` and evaluates the file — so what runs here is the
// same bytes the browser and the Capacitor shell load, not a copy that can
// drift from them.
//
// What this protects: the rule that a 13- or 14-digit all-digit code starting
// with zero loses exactly one zero, and NOTHING else changes. Every case below
// is either the Colac evidence or a barcode that would be corrupted by a
// carelessly widened rule — 12-digit UPC-A beginning with a real zero above all.

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const file = path.join(__dirname, '..', 'barcode-export.js');
const sandbox = { window: {} };
vm.runInNewContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const { normaliseBarcodeForExport, mergeItemsForExport } = sandbox.window.GANTRY_EXPORT;

let failures = 0;
let checks = 0;

function eq(actual, expected, label) {
  checks++;
  const a = JSON.stringify(actual);
  const e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`  FAIL  ${label}\n        expected ${e}\n        actual   ${a}`);
}

const ON = { stripLeadingZero: true };
const OFF = { stripLeadingZero: false };

// ---------------------------------------------------------------------------
// normaliseBarcodeForExport — setting ON
// ---------------------------------------------------------------------------
console.log('normaliseBarcodeForExport, setting ON');

// The Colac case: Bepoz holds "797776409853".
eq(normaliseBarcodeForExport('0797776409853', ON), '797776409853',
   '13 digits leading zero -> one zero removed');

// Tyrrell's Semillon: captured with "00", Bepoz holds a single "0".
eq(normaliseBarcodeForExport('009300727001234', ON), '009300727001234',
   '15 digits is not a GTIN length -> unchanged');
eq(normaliseBarcodeForExport('00930072700123', ON), '0930072700123',
   '14 digits "00" -> "0" + 12 (one zero only)');

// Already the POS form.
eq(normaliseBarcodeForExport('797776409853', ON), '797776409853',
   '12 digits -> unchanged');

// No leading zero at all — the overwhelming majority of Australian retail.
eq(normaliseBarcodeForExport('9369998094189', ON), '9369998094189',
   '13 digits, no leading zero -> unchanged');

// EAN-8.
eq(normaliseBarcodeForExport('95049809', ON), '95049809',
   '8 digits -> unchanged');

// The one that matters most: a 12-digit UPC-A whose FIRST DIGIT is a real zero.
// Stripping this would break a line that already matched.
eq(normaliseBarcodeForExport('012345678905', ON), '012345678905',
   '12 digits with leading zero -> unchanged (real UPC-A number system 0)');

// Not all digits: QR payloads are URLs, Code 128/39 are alphanumeric.
eq(normaliseBarcodeForExport('0ABC1234567890', ON), '0ABC1234567890',
   'not all digits -> unchanged');
eq(normaliseBarcodeForExport('https://example.com/wine', ON), 'https://example.com/wine',
   'QR URL payload -> unchanged');

// Edges that must not throw or invent a value.
eq(normaliseBarcodeForExport('', ON), '', 'empty string -> empty string');
eq(normaliseBarcodeForExport(null, ON), '', 'null -> empty string');
eq(normaliseBarcodeForExport(undefined, ON), '', 'undefined -> empty string');
eq(normaliseBarcodeForExport('0000000000000', ON), '000000000000',
   'all zeros, 13 long -> one zero removed, no loop');
eq(normaliseBarcodeForExport(' 0797776409853', ON), ' 0797776409853',
   'leading space -> unchanged (not all digits)');

// ---------------------------------------------------------------------------
// normaliseBarcodeForExport — setting OFF, and absent
// ---------------------------------------------------------------------------
console.log('normaliseBarcodeForExport, setting OFF');

[
  '0797776409853', '00930072700123', '797776409853', '9369998094189',
  '95049809', '012345678905', '0ABC1234567890', '',
].forEach(function (code) {
  eq(normaliseBarcodeForExport(code, OFF), code, `OFF: ${code || '(empty)'} -> unchanged`);
  eq(normaliseBarcodeForExport(code, undefined), code, `no opts: ${code || '(empty)'} -> unchanged`);
  eq(normaliseBarcodeForExport(code, {}), code, `empty opts: ${code || '(empty)'} -> unchanged`);
});

// ---------------------------------------------------------------------------
// mergeItemsForExport
// ---------------------------------------------------------------------------
console.log('mergeItemsForExport');

// The Colac merge: two stored lines, one product, 10 + 1 = 11.
const twoLines = [
  { barcode: '0797776409853', qty: '10.00', first_scanned: '2026-09-29T02:00:00Z', last_scanned: '2026-09-29T02:05:00Z' },
  { barcode: '797776409853', qty: '1.00', first_scanned: '2026-09-29T01:00:00Z', last_scanned: '2026-09-29T03:00:00Z' },
];

const merged = mergeItemsForExport(twoLines, ON);
eq(merged.length, 1, 'ON: two paddings of one product -> one line');
eq(merged[0].barcode, '797776409853', 'ON: merged line carries the POS barcode');
eq(merged[0].qty, 11, 'ON: quantities summed (10 + 1 = 11)');
eq(merged[0].first_scanned, '2026-09-29T01:00:00Z', 'ON: earliest first_scanned wins');
eq(merged[0].last_scanned, '2026-09-29T03:00:00Z', 'ON: latest last_scanned wins');

const unmerged = mergeItemsForExport(twoLines, OFF);
eq(unmerged.length, 2, 'OFF: stays two lines');
eq(unmerged.map((r) => r.barcode), ['0797776409853', '797776409853'], 'OFF: barcodes untouched');
eq(unmerged.map((r) => r.qty), [10, 1], 'OFF: quantities untouched');

// The caller's rows must not be mutated — they are also the Home card's snapshot.
eq(twoLines[0].barcode, '0797776409853', 'input row barcode not mutated');
eq(twoLines[0].qty, '10.00', 'input row qty not mutated');

// Part bottles: numeric-as-string addition must not concatenate, and binary
// float dust must not reach the file.
const parts = mergeItemsForExport([
  { barcode: '0797776409853', qty: '0.10' },
  { barcode: '797776409853', qty: '0.20' },
], ON);
eq(parts[0].qty, 0.3, 'part bottles: 0.10 + 0.20 = 0.3, not 0.30000000000000004');

// ONE zero per code, one pass — not "strip until it stops changing".
//
// This pins a real and deliberate asymmetry. A 14-digit "00…" lands on 13; a
// stored 13-digit "0…" lands on 12, and therefore merges with the 12-digit form
// rather than with the 14. The three paddings of one product do NOT converge on
// a single line, because there is no way to know from the digits alone whether
// the POS holds the 12- or the 13-digit form — Bepoz at Colac held one of each
// for two different products. Removing one zero is what the evidence supports;
// looping would be a guess, and a silent one.
const three = mergeItemsForExport([
  { barcode: '00930072700123', qty: 1 },
  { barcode: '0930072700123', qty: 2 },
  { barcode: '930072700123', qty: 4 },
  { barcode: '9369998094189', qty: 8 },
], ON);
eq(three.length, 3, 'ON: 13 joins the 12; the 14 lands on 13 and stays its own line');
eq(three.map((r) => [r.barcode, r.qty]),
   [['0930072700123', 1], ['930072700123', 6], ['9369998094189', 8]],
   'ON: one zero per code, one pass — the three paddings do not all converge');

// Order is first appearance, and absent timestamps don't throw.
const order = mergeItemsForExport([
  { barcode: '9369998094189', qty: 1 },
  { barcode: '0797776409853', qty: 1 },
  { barcode: '95049809', qty: 1 },
], ON);
eq(order.map((r) => r.barcode), ['9369998094189', '797776409853', '95049809'],
   'first-appearance order preserved');

// Defensive shapes.
eq(mergeItemsForExport([], ON), [], 'empty list -> empty list');
eq(mergeItemsForExport(null, ON), [], 'null list -> empty list');
eq(mergeItemsForExport([null, { barcode: '95049809', qty: 2 }], ON).length, 1,
   'null row skipped');
eq(mergeItemsForExport([{ barcode: '0797776409853', qty: 'nonsense' }], ON)[0].qty, 0,
   'unparseable qty -> 0, never NaN in a CSV');

// Other columns survive the copy: the Gantry CSV reads them.
const keys = Object.keys(mergeItemsForExport(
  [{ id: 'abc', stocktake_id: 'st1', barcode: '95049809', qty: 1, first_scanned: 'x', last_scanned: 'y' }],
  ON,
)[0]).sort();
eq(keys, ['barcode', 'first_scanned', 'id', 'last_scanned', 'qty', 'stocktake_id'],
   'all columns carried through');

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures) {
  console.error(`${failures} FAILED`);
  process.exit(1);
}
