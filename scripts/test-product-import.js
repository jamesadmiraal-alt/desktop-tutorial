// node scripts/test-product-import.js
//
// product-import.js: CSV parsing, column guessing, validation, and the barcode
// key — which must agree with public.barcode_key() in the migration, or a
// barcode imported in one form won't match the same barcode scanned in another.
const fs = require('fs');
const path = require('path');
const vm = require('vm');

const root = path.join(__dirname, '..');
const sandbox = { window: {} };
vm.runInNewContext(fs.readFileSync(path.join(root, 'product-import.js'), 'utf8'), sandbox, { filename: 'product-import.js' });
const P = sandbox.window.GANTRY_PRODUCT_IMPORT;

let failures = 0, checks = 0;
function eq(actual, expected, label) {
  checks++;
  const a = JSON.stringify(actual), e = JSON.stringify(expected);
  if (a === e) return;
  failures++;
  console.error(`  FAIL  ${label}\n        expected ${e}\n        actual   ${a}`);
}

// ---------------------------------------------------------------------------
console.log('CSV');
eq(P.parseCsv('a,b\r\n1,2\r\n').rows, [['a', 'b'], ['1', '2']], 'CRLF');
eq(P.parseCsv('a,b\n1,2').rows, [['a', 'b'], ['1', '2']], 'LF, no final newline');
eq(P.parseCsv('a,b\r1,2\r').rows, [['a', 'b'], ['1', '2']], 'lone CR');
eq(P.parseCsv('﻿code,name\n1,x').rows[0], ['code', 'name'], 'BOM dropped');
eq(P.parseCsv('code,name\n1,"Coopers, Pale ""Ale"""').rows[1], ['1', 'Coopers, Pale "Ale"'], 'quoted comma and doubled quotes');
eq(P.parseCsv('code,name\n1,"two\nlines"').rows[1], ['1', 'two\nlines'], 'newline inside quotes');
eq(P.parseCsv('code;name;pack\n1;x;24').delimiter, ';', 'semicolon detected');
eq(P.parseCsv('code\tname\n1\tx').rows[1], ['1', 'x'], 'tab detected');
eq(P.parseCsv('"a,b";c;d\n1;2;3').delimiter, ';', 'a comma inside quotes does not decide the delimiter');
eq(P.parseCsv('a,b\n1,2\n\n,\n').rows.length, 2, 'trailing blank lines dropped');
eq(P.parseCsv('a,b\n1,').rows[1], ['1', ''], 'empty last field kept');

// ---------------------------------------------------------------------------
console.log('column guesses');
eq(P.guessMapping(['Product Code', 'Description', 'Pack Size', 'Barcode', 'Carton Barcode', 'Sell Price']),
   ['pos_code', 'description', 'pack_size', 'unit_barcode', 'carton_barcode', 'ignore'], 'typical export');
eq(P.guessMapping(['PLU', 'Name', 'Units Per Carton', 'EAN', 'Outer EAN']),
   ['pos_code', 'description', 'pack_size', 'unit_barcode', 'carton_barcode'], 'other wording');
eq(P.guessMapping(['Code', 'Code', 'Description']), ['pos_code', 'ignore', 'description'], 'a second code column is ignored, not doubled');
eq(P.guessMapping(['Stock Code', 'Barcode 1', 'Barcode 2']), ['pos_code', 'unit_barcode', 'unit_barcode'], 'several barcode columns');
eq(P.guessRole('Supplier'), 'ignore', 'unknown columns are ignored');

const saved = P.savedFromMapping(['Code', 'Desc', 'Junk'], ['pos_code', 'description', 'ignore']);
eq(saved, { Code: 'pos_code', Desc: 'description' }, 'saved by header name, ignore left out');
eq(P.mappingFromSaved(['Junk', 'Desc', 'Code', 'New'], saved), ['ignore', 'description', 'pos_code', 'ignore'], 'reapplied by name in a new column order');
eq(P.mappingFromSaved(['Code', 'Something else'], saved), null, 'a changed export is not half-remembered');

// ---------------------------------------------------------------------------
console.log('barcode key');
eq(P.barcodeKey('012345678905'), '00012345678905', 'UPC-A -> 14');
eq([P.barcodeKey('0012345678905'), P.barcodeKey('00012345678905')], ['00012345678905', '00012345678905'], 'EAN-13 and GTIN-14 of the same item: same key');
eq(P.barcodeKey(' 95049809 '), '00000095049809', 'EAN-8 padded, trimmed');
eq(P.barcodeKey('abc-12'), 'ABC-12', 'non-numeric: trimmed and upper-cased');
eq(P.barcodeKey('123456789012345'), '123456789012345', 'more than 14 digits is left alone');
const sql = fs.readFileSync(path.join(root, 'supabase/migrations/20261024_01_receiving_product_master.sql'), 'utf8').replace(/\r\n/g, '\n');
const fn = sql.match(/create or replace function public\.barcode_key[\s\S]*?\$\$;/);
eq(!!fn, true, 'SQL barcode_key() found in the migration');
eq(!!(fn && /'\^\[0-9\]\{1,14\}\$'/.test(fn[0]) && /lpad\(btrim\(p\), 14, '0'\)/.test(fn[0]) && /upper\(btrim/.test(fn[0])),
   true, 'SQL barcode_key() has the same rule: 1–14 digits -> lpad 14, else upper(trim)');
const schema = fs.readFileSync(path.join(root, 'schema.sql'), 'utf8').replace(/\r\n/g, '\n');
eq(schema.includes(fn ? fn[0] : '<none>'), true, 'schema.sql carries the identical barcode_key()');

// ---------------------------------------------------------------------------
console.log('rows -> products');
const csv = [
  'Product Code,Description,Pack Size,Barcode,Carton Barcode,Price',
  '1001,Coopers Pale Ale 375ml,24,9312345000011,19312345000018,2.50',
  '1002,Hahn Super Dry 330ml,24 x 330ml,9312345000028; 09312345000028,,2.20',   // same barcode twice (key-equal)
  '1003,No barcode wine,,,,15',
  ',Missing code,6,9312345000035,,1',
  '1001,Duplicate code,24,9312345000042,,1',
  '1004,Shares a barcode,6,9312345000011,,1',
  '1005,Carton no pack,,9312345000059,19312345000056,1',
  '1006,Excel mangled,12,9.31234E+12,,1',
  '1007,Bad pack,abc,9312345000066,,1',
].join('\r\n');
const parsed = P.parseCsv(csv);
const roles = P.guessMapping(parsed.rows[0]);
const out = P.buildProducts(parsed.rows, roles, { hasHeader: true });
eq(out.products.map((p) => p.pos_code), ['1001', '1002', '1003', '1004', '1005', '1006', '1007'], 'missing-code and duplicate-code rows left out');
eq(out.products[0], { pos_code: '1001', description: 'Coopers Pale Ale 375ml', pack_size: 24,
  barcodes: [{ barcode: '9312345000011', kind: 'unit', units: 1 }, { barcode: '19312345000018', kind: 'carton', units: 24 }] },
  'unit + carton barcode; carton converts to the pack size');
eq(out.products[1].pack_size, 24, '"24 x 330ml" reads as a pack of 24');
eq(out.products[1].barcodes.length, 1, 'the same barcode written two ways is one barcode');
eq(out.products[3].barcodes, [], 'a barcode already owned by another product is not stolen');
eq(out.products[4].barcodes.map((b) => b.kind), ['unit'], 'a carton barcode without a pack size is left out');
eq(out.products[5].barcodes, [], 'an Excel-mangled barcode is refused');
eq(out.products[6].pack_size, null, 'an unreadable pack size is left blank');
const msgs = out.problems.map((p) => p.row + ':' + p.level);
eq(msgs.includes('5:error') && msgs.includes('6:error'), true, 'missing code and duplicate code are errors, with spreadsheet row numbers');
eq(out.problems.some((p) => p.row === 4 && /no barcode/.test(p.message)), true, 'no barcode at all is a warning');
eq(out.problems.some((p) => p.row === 9 && /Excel/.test(p.message)), true, 'Excel scientific notation is explained');
eq(out.stats, { rows: 9, products: 7, barcodes: 5, skipped: 2 }, 'stats');
eq(P.buildProducts(parsed.rows, roles.map((r) => (r === 'pos_code' ? 'ignore' : r))).problems[0].message,
   'Choose which column is the product code.', 'no code column: one clear problem');
eq(P.buildProducts([['1', 'x']], ['pos_code', 'description'], { hasHeader: false }).products.length, 1, 'no header row');

// ---------------------------------------------------------------------------
console.log('batches');
eq(P.chunk([1, 2, 3, 4, 5], 2), [[1, 2], [3, 4], [5]], 'chunked');

console.log(`\n${checks - failures}/${checks} checks passed`);
if (failures) process.exit(1);
