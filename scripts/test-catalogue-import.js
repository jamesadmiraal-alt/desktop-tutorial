// node scripts/test-catalogue-import.js
//
// The venue product catalogue import (product-import.js, second half): reading
// a spreadsheet with the vendored SheetJS, recognising Bepoz's "Product List:
// Barcodes" layout, the barcode rules agreed on 27 Oct 2026, sizes, and the
// barcode key, which must agree with public.barcode_key() in 20261027_01.
//
// The fixture is MADE UP, in the same shape as a real Bepoz export (Name,
// SizeN Name / SizeN Barcodes, a "Totals:" row, "; " between barcodes). A
// venue's real product file must never be committed.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const sandbox = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(root, 'product-import.js'), 'utf8'), sandbox, { filename: 'product-import.js' });
const P = sandbox.window.GANTRY_PRODUCT_IMPORT;
const XLSX = require(path.join(root, 'xlsx.full.min.js'));

let failures = 0, checks = 0;
function eq(actual, expected, label) {
  checks++;
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`  FAIL  ${label}\n        expected ${e}\n        actual   ${a}`);
}

// ---------------------------------------------------------------------------
console.log('barcode rules');
eq(P.checkBarcode('9300000000019'), { barcode: '9300000000019' }, 'a good EAN-13');
eq(P.checkBarcode(' 0724022295403 '), { barcode: '0724022295403' }, 'trimmed; a leading zero is fine');
eq(P.checkBarcode('12345670'), { barcode: '12345670' }, 'a good EAN-8');
eq(P.checkBarcode('9300000000018').warning, 'the last digit fails the barcode check, so a digit may be wrong', 'bad check digit: imported with a warning');
eq(P.checkBarcode('1234').warning, 'short in-store code (4 digits)', 'short in-store code: warning');
eq(P.checkBarcode('1234567890').warning, '10 digits; shop barcodes have 8, 12, 13 or 14', '9 to 11 digits: warning');
eq(P.checkBarcode('ABC-123').warning, 'custom code (not all digits)', 'letters: custom code, warning');
eq(!!P.checkBarcode('9.31234E+12').reject, true, 'scientific notation: refused');
eq(!!P.checkBarcode('9.31234e12').reject, true, 'scientific notation, lower case: refused');
eq(!!P.checkBarcode('23.859310876020066').reject, true, 'a decimal: refused');
eq(!!P.checkBarcode('9300000000019.0').reject, true, 'a ".0" ending: refused');
eq(!!P.checkBarcode('58739369998186150').reject, true, '17 digits: refused');
eq(P.checkBarcode('   '), null, 'blank: nothing');
eq(P.gs1CheckOk('09300000000019'), true, 'GTIN-14 check');

// ---------------------------------------------------------------------------
console.log('barcode key agrees with the SQL');
const mig = fs.readFileSync(path.join(root, 'supabase/migrations/20261027_01_venue_product_catalogue.sql'), 'utf8');
const fn = mig.match(/create or replace function public\.barcode_key\(p text\)[\s\S]*?\$\$([\s\S]*?)\$\$/);
eq(!!fn, true, 'barcode_key() found in the migration');
eq(fn && fn[1].replace(/\s+/g, ' ').trim(),
   "select case when btrim(coalesce(p, '')) ~ '^[0-9]{1,14}$' then lpad(btrim(p), 14, '0') else upper(btrim(coalesce(p, ''))) end",
   'the SQL is the rule this test models (change both together)');
const sqlKey = (p) => { const t = String(p == null ? '' : p).trim(); return /^[0-9]{1,14}$/.test(t) ? t.padStart(14, '0') : t.toUpperCase(); };
['724022295403', '0724022295403', '00724022295403', '1234', ' abc-1 ', '', '123456789012345'].forEach((c) => eq(P.barcodeKey(c), sqlKey(c), 'key of ' + JSON.stringify(c)));

// ---------------------------------------------------------------------------
console.log('sizes');
eq(P.sizeInfo('Bottle'), { kind: 'unit', units: 1 }, 'Bottle');
eq(P.sizeInfo('4pk'), { kind: 'pack', units: 4 }, '4pk');
eq(P.sizeInfo('4 Pack'), { kind: 'pack', units: 4 }, '4 Pack');
eq(P.sizeInfo('10pks'), { kind: 'pack', units: 10 }, '10pks');
eq(P.sizeInfo('24pk'), { kind: 'carton', units: 24 }, '24pk is a carton of 24');
eq(P.sizeInfo('Carton'), { kind: 'carton', units: 24 }, 'Carton is 24 (agreed)');
eq(P.sizeInfo('Case'), { kind: 'carton', units: null }, 'Case: size not agreed yet');
eq(P.sizeInfo('Case 24'), { kind: 'carton', units: 24 }, 'Case 24');
eq(P.sizeInfo(''), { kind: 'unit', units: 1 }, 'no size name');

// ---------------------------------------------------------------------------
console.log('a Bepoz-shaped spreadsheet, through SheetJS');
const H = ['Name', 'Size1\n Name', 'Size1\n Barcodes', 'Size2\n Name', 'Size2\n Barcodes', 'Size3\n Name', 'Size3\n Barcodes',
           'Qty\n onHand', 'Parent\n Name', 'Minimum\n Stock', 'Maximum\n Stock', 'Store\n List'];
const aoa = [
  H,
  ['Totals:', '', '', '', '', '', '', '1,234.0000', '', '10.00', '20.00', ''],
  ['Test Lager Cans', 'Can', '9300000000019', '4pk', '9300000000026', 'Case', '9300000000033', '', 'Packaged Beer', '', '', 'Bar'],
  ['Test Gin 700ml', '30ml', '', 'Bottle', '9300000000040; 9300000000057', '', '', '', 'Gin', '', '', 'Bar'],
  ['Espresso Martini', '', '', '', '', '', '', '', 'Cocktails', '', '', 'Bar'],                       // nothing to scan
  ['Test Tonic', 'Bottle', '05000000000012; 5000000000012', '', '', '', '', '', 'Mixers', '', '', 'Bar'],   // one code, two forms
  ['Test Cello', 'Bottle', '58739369998186150; 9300000000064', '', '', '', '', '', 'Liqueur', '', '', 'Bar'],
  ['Test Bitters', 'Bottle', '9300000000071', '', '', '', '', '', 'Bitters', '', '', 'Bar'],
  ['Test Amaro', 'Bottle', '9300000000071', '', '', '', '', '', 'Amaro', '', '', 'Bar'],               // duplicate of the row above
  ['Test Cans Odd', 'Can', '23.859310876020066', '', '', '', '', '', 'Beer', '', '', 'Bar'],          // only a bad code
  ['House Pie', 'Single', '2041', '', '', '', '', '', 'Food', '', '', 'Bar'],                          // short in-store code
  ['Test Cider', 'Carton', '9300000000088', '', '', '', '', '', 'Cider', '', '', 'Bar'],
  ['', '', '', '', '', '', '', '', '', '', '', ''],
];
const ws = XLSX.utils.aoa_to_sheet(aoa);
// A barcode typed into a NUMBER cell, as Excel shows it "9.30E+12": the value keeps every digit.
ws['C14'] = { t: 'n', v: 9300000000095, w: '9.30E+12' };
ws['A14'] = { t: 's', v: 'Number Cell Beer' };
ws['B14'] = { t: 's', v: 'Can' };
ws['!ref'] = 'A1:L14';
const wb = XLSX.utils.book_new();
XLSX.utils.book_append_sheet(wb, ws, 'Product List');
const buf = XLSX.write(wb, { type: 'buffer', bookType: 'xlsx' });
const read = XLSX.read(buf);
const rows = P.sheetRows(XLSX, read.Sheets[read.SheetNames[0]]);
eq(rows[13] && rows[13][2], '9300000000095', 'a barcode in a number cell keeps every digit (not 9.30E+12)');

const layout = P.detectLayout(rows[0]);
eq([layout.layout, layout.nameCol, layout.groupCol, layout.sizes.length], ['bepoz', 0, 8, 3], 'Bepoz layout recognised (line breaks in the headers)');
const out = P.buildCatalogue(rows, layout);
eq(out.stats, { rows: 11, products: 8, barcodes: 11, warnings: 1, rejected: 2, duplicates: 1, noBarcode: 3, skipped: 0 }, 'counts');
const byName = {}; out.products.forEach((p) => { byName[p.name] = p; });
eq(byName['Test Lager Cans'].barcodes.map((b) => [b.barcode, b.size_name, b.kind, b.units]),
   [['9300000000019', 'Can', 'unit', 1], ['9300000000026', '4pk', 'pack', 4], ['9300000000033', 'Case', 'carton', null]], 'three sizes, three barcodes');
eq(byName['Test Lager Cans'].group_name, 'Packaged Beer', 'Parent Name is the group');
eq(byName['Test Gin 700ml'].barcodes.map((b) => b.barcode), ['9300000000040', '9300000000057'], '"; " splits a cell into two barcodes');
eq(byName['Test Tonic'].barcodes.map((b) => b.barcode), ['05000000000012'], 'the 14- and 13-digit forms of one code: kept once');
eq(byName['Test Cello'].barcodes.map((b) => b.barcode), ['9300000000064'], '17-digit code left out; the good one kept');
eq(byName['Test Amaro'], undefined, 'a product whose only code belongs to an earlier row is left out');
eq(byName['Test Cans Odd'], undefined, 'a product with only a refused code is left out');
eq(byName['Espresso Martini'], undefined, 'nothing to scan: left out');
eq(byName['House Pie'].barcodes[0].warning, 'short in-store code (4 digits)', 'short code imported, with its warning');
eq(byName['Test Cider'].barcodes[0].units, 24, 'Carton: 24 units');
eq(byName['Number Cell Beer'].barcodes[0].barcode, '9300000000095', 'number-cell barcode imported in full');
eq(out.problems.filter((p) => p.level === 'error').map((p) => p.row), [7, 9, 10], 'left-out problems name their spreadsheet rows');
eq(out.problems.find((p) => p.row === 9).message, 'barcode 9300000000071 is already listed for "Test Bitters" (row 8), so it stays there', 'the duplicate says where the code stays');

const csv = P.problemsCsv(out.problems);
eq(csv.split('\r\n')[0], 'Row,Product,Barcode,Result,Problem', 'problems CSV header');
eq(/^7,Test Cello,58739369998186150,Left out,/.test(csv.split('\r\n')[1]), true, 'problems CSV row');
eq(/—/.test(csv + JSON.stringify(out.problems)), false, 'no em dashes in the messages');

// ---------------------------------------------------------------------------
console.log('a plain table (any POS)');
const t = [['PLU', 'Description', 'Category', 'Barcode', 'Carton Barcode', 'Units per carton', 'Price'],
           ['G1', 'Gin One', 'Gin', '9300000000019', '19300000000016', '6', '45'],
           ['G1', 'Gin One again', 'Gin', '9300000000026', '', '', '45'],
           ['B2', 'Beer Two', 'Beer', '9300000000033', '', '', '5']];
const tl = P.detectLayout(t[0]);
eq(tl, { layout: 'columns', roles: ['item_code', 'name', 'group_name', 'barcode', 'carton_barcode', 'carton_units', 'ignore'] }, 'columns guessed');
const to = P.buildCatalogue(t, tl);
eq(to.products.map((p) => [p.item_code, p.name, p.barcodes.map((b) => b.kind + ':' + b.units)]),
   [['G1', 'Gin One', ['unit:1', 'carton:6']], ['B2', 'Beer Two', ['unit:1']]], 'code, name, carton units from their column');
eq(to.problems[0].message, 'product code G1 is already on row 2, so this row was left out', 'a repeated product code is left out');
eq(P.buildCatalogue(t, { layout: 'columns', roles: ['item_code', 'ignore', 'ignore', 'barcode'] }).problems[0].message,
   'Choose which column is the product name.', 'no name column: asks for one');

console.log(failures ? `\n${failures} of ${checks} checks FAILED` : `\n${checks}/${checks} checks passed`);
process.exit(failures ? 1 : 0);
