// Product master import — reading a POS product export (H&L, Bepoz, any CSV)
// into Gantry's product list. Receiving invoices (coming soon), Phase 1.
//
// Pure functions, no DOM and no network, same shape as export-engine.js, so
// scripts/test-product-import.js can run it in node. receiving.html does the
// talking to Supabase; everything about what a file MEANS lives here.
//
//   parseCsv(text)            -> { rows: string[][], delimiter }
//   guessRole(header)         -> 'pos_code' | 'description' | 'pack_size' |
//                                'unit_barcode' | 'carton_barcode' | 'ignore'
//   guessMapping(headers)     -> roles[] (one per column)
//   mappingFromSaved(headers, saved) -> roles[] | null
//   buildProducts(rows, roles, opts) -> { products, problems, stats }
//   barcodeKey(code)          -> the matching key; MUST equal SQL barcode_key()
//   chunk(list, n)            -> list of lists
//
// The column roles are deliberately few. A POS export has dozens of columns;
// receiving needs four facts per product — its POS code, what it's called, how
// many units are in a carton, and which barcodes mean it — and anything else
// is ignored rather than guessed at.
window.GANTRY_PRODUCT_IMPORT = (function () {
  'use strict';

  var ROLES = ['ignore', 'pos_code', 'description', 'pack_size', 'unit_barcode', 'carton_barcode'];
  var ROLE_LABELS = {
    ignore: 'Ignore',
    pos_code: 'Product code',
    description: 'Description',
    pack_size: 'Pack size (units per carton)',
    unit_barcode: 'Barcode — single unit',
    carton_barcode: 'Barcode — carton',
  };

  // ---- CSV -----------------------------------------------------------------
  //
  // RFC 4180, plus what real exports do: a UTF-8 BOM, CRLF or LF or lone CR,
  // and a delimiter that isn't always a comma (Bepoz and Excel in some locales
  // write semicolons; some exports are tab-separated). The delimiter is the
  // candidate that appears most often OUTSIDE quotes on the first line.
  function detectDelimiter(text) {
    var firstLine = '', inQ = false;
    for (var i = 0; i < text.length; i++) {
      var ch = text[i];
      if (ch === '"') inQ = !inQ;
      else if (!inQ && (ch === '\n' || ch === '\r')) break;
      firstLine += inQ ? '' : ch;
    }
    var best = ',', bestN = 0;
    [',', ';', '\t', '|'].forEach(function (d) {
      var n = firstLine.split(d).length - 1;
      if (n > bestN) { best = d; bestN = n; }
    });
    return best;
  }

  function parseCsv(text) {
    text = String(text || '');
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    var d = detectDelimiter(text);
    var rows = [], row = [], field = '', inQ = false, i = 0, n = text.length;
    while (i < n) {
      var ch = text[i];
      if (inQ) {
        if (ch === '"') {
          if (text[i + 1] === '"') { field += '"'; i += 2; continue; }
          inQ = false; i++; continue;
        }
        field += ch; i++; continue;
      }
      if (ch === '"' && field === '') { inQ = true; i++; continue; }
      if (ch === d) { row.push(field); field = ''; i++; continue; }
      if (ch === '\r' || ch === '\n') {
        row.push(field); field = '';
        rows.push(row); row = [];
        if (ch === '\r' && text[i + 1] === '\n') i++;
        i++; continue;
      }
      field += ch; i++;
    }
    if (field !== '' || row.length) { row.push(field); rows.push(row); }
    // Trailing blank lines are not rows.
    while (rows.length && rows[rows.length - 1].every(function (c) { return c.trim() === ''; })) rows.pop();
    return { rows: rows, delimiter: d };
  }

  // ---- Which column is which ------------------------------------------------
  //
  // By header name. Carton is checked before unit: "Carton Barcode" contains
  // "barcode" too. Anything unrecognised is ignored, never guessed — the
  // operator sees every column and its guess, and can change any of them.
  function norm(h) { return String(h || '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim(); }

  function guessRole(header) {
    var h = norm(header);
    if (!h) return 'ignore';
    var isBarcode = /\b(barcode|bar code|ean|upc|gtin|apn)\b/.test(h) || /barcode/.test(h);
    if (isBarcode) {
      if (/\b(carton|ctn|case|cs|outer|pack|inner|tray)\b/.test(h)) return 'carton_barcode';
      return 'unit_barcode';
    }
    if (/\b(pack size|pack qty|units per|qty per|per carton|per case|carton qty|case qty|carton size|case size|ctn qty|pack)\b/.test(h)) return 'pack_size';
    if (/^(product code|item code|stock code|stockcode|code|plu|sku|product id|item id|item no|item number|product number|prod code|id)$/.test(h)) return 'pos_code';
    if (/\b(description|desc|product name|item name|name|product)\b/.test(h)) return 'description';
    return 'ignore';
  }

  function guessMapping(headers) {
    var roles = headers.map(guessRole);
    // One code, one description, one pack size: keep the first guess of each
    // and ignore the rest — two "code" columns is a question for the operator,
    // not something to resolve by picking one silently later.
    ['pos_code', 'description', 'pack_size'].forEach(function (single) {
      var seen = false;
      roles = roles.map(function (r) {
        if (r !== single) return r;
        if (seen) return 'ignore';
        seen = true; return r;
      });
    });
    return roles;
  }

  // A mapping saved by header NAME (from the last import of this POS) applied
  // to a new file's headers — null unless every saved header is still there,
  // so a changed export is mapped afresh rather than half-remembered.
  function mappingFromSaved(headers, saved) {
    if (!saved || typeof saved !== 'object') return null;
    var names = Object.keys(saved);
    if (!names.length) return null;
    var byName = {};
    headers.forEach(function (h, i) { byName[String(h).trim()] = i; });
    if (!names.every(function (n) { return n in byName; })) return null;
    return headers.map(function (h) {
      var r = saved[String(h).trim()];
      return ROLES.indexOf(r) !== -1 ? r : 'ignore';
    });
  }

  function savedFromMapping(headers, roles) {
    var out = {};
    headers.forEach(function (h, i) { if (roles[i] && roles[i] !== 'ignore') out[String(h).trim()] = roles[i]; });
    return out;
  }

  // ---- Barcodes -------------------------------------------------------------
  //
  // Stored as imported; MATCHED on this key. An all-digit code is right-aligned
  // to 14 digits (GTIN-14), so 12-, 13- and 14-digit renderings of one bottle
  // are one key. Must equal public.barcode_key() in the migration exactly —
  // scripts/test-product-import.js parses that SQL and checks.
  function barcodeKey(code) {
    var t = String(code == null ? '' : code).trim();
    if (/^[0-9]{1,14}$/.test(t)) return ('00000000000000' + t).slice(-14);
    return t.toUpperCase();
  }

  // One cell can hold several barcodes ("9300…; 9301…"). Excel also turns a
  // long barcode into 9.30001E+12, which has lost digits for good — refused,
  // with the reason, rather than imported as a wrong number.
  function splitBarcodes(cell) {
    return String(cell || '').split(/[;|,\s]+/).map(function (s) { return s.trim(); }).filter(Boolean);
  }
  function badBarcodeReason(b) {
    if (/^[0-9.]+e\+?[0-9]+$/i.test(b)) return 'looks like Excel turned it into a number (' + b + ') — export the file again as text';
    if (b.length > 48) return 'is too long to be a barcode';
    return null;
  }

  function packSizeOf(cell) {
    var t = String(cell == null ? '' : cell).trim();
    if (t === '') return { value: null };
    var m = t.match(/^(\d+)(?:\.0+)?$/);
    if (!m) {
      // "24 x 375ml", "CTN24": a leading or trailing count is the pack size.
      var m2 = t.match(/^(\d+)\s*[x×]/i) || t.match(/(?:ctn|case|pk|pack)\s*(\d+)$/i);
      if (m2) m = m2;
    }
    if (!m) return { value: null, problem: 'pack size "' + t + '" isn’t a whole number' };
    var v = parseInt(m[1], 10);
    if (!(v >= 1) || v > 10000) return { value: null, problem: 'pack size "' + t + '" is out of range' };
    return { value: v };
  }

  // ---- Rows -> products ------------------------------------------------------
  //
  // opts.hasHeader (default true). Returns:
  //   products  [{ pos_code, description, pack_size, barcodes: [{ barcode, kind, units }] }]
  //   problems  [{ row (1-based, as in a spreadsheet), message, level: 'error'|'warning' }]
  //   stats     { rows, products, barcodes, skipped }
  //
  // An ERROR row is left out of products; a WARNING row goes in with the bad
  // part dropped. Nothing is ever silently changed into something else.
  function buildProducts(rows, roles, opts) {
    opts = opts || {};
    var hasHeader = opts.hasHeader !== false;
    var problems = [];
    var products = [];
    var byCode = {};
    var barcodeOwner = {};   // key -> pos_code, across the whole file
    var nBarcodes = 0, skipped = 0;
    var codeCol = roles.indexOf('pos_code');
    if (codeCol === -1) {
      return { products: [], problems: [{ row: 0, level: 'error', message: 'Choose which column is the product code.' }],
               stats: { rows: 0, products: 0, barcodes: 0, skipped: 0 } };
    }
    var start = hasHeader ? 1 : 0;
    for (var i = start; i < rows.length; i++) {
      var r = rows[i];
      var line = i + 1;
      if (r.every(function (c) { return String(c).trim() === ''; })) continue;
      var code = String(r[codeCol] || '').trim();
      if (!code) { problems.push({ row: line, level: 'error', message: 'no product code — skipped' }); skipped++; continue; }
      if (byCode[code]) { problems.push({ row: line, level: 'error', message: 'product code ' + code + ' appears again (first on row ' + byCode[code].row + ') — skipped' }); skipped++; continue; }

      var p = { pos_code: code, description: '', pack_size: null, barcodes: [] };
      var units = [], cartons = [];
      for (var c = 0; c < roles.length; c++) {
        var cell = r[c] == null ? '' : r[c];
        switch (roles[c]) {
          case 'description': if (!p.description) p.description = String(cell).trim().slice(0, 300); break;
          case 'pack_size': {
            var ps = packSizeOf(cell);
            if (ps.problem) problems.push({ row: line, level: 'warning', message: code + ': ' + ps.problem + ' — left blank' });
            if (ps.value) p.pack_size = ps.value;
            break;
          }
          case 'unit_barcode': units = units.concat(splitBarcodes(cell)); break;
          case 'carton_barcode': cartons = cartons.concat(splitBarcodes(cell)); break;
        }
      }
      var add = function (b, kind) {
        var bad = badBarcodeReason(b);
        if (bad) { problems.push({ row: line, level: 'warning', message: code + ': barcode ' + bad }); return; }
        var key = barcodeKey(b);
        if (barcodeOwner[key] && barcodeOwner[key] !== code) {
          problems.push({ row: line, level: 'warning', message: code + ': barcode ' + b + ' already belongs to ' + barcodeOwner[key] + ' — kept there' });
          return;
        }
        if (p.barcodes.some(function (x) { return barcodeKey(x.barcode) === key; })) return;   // same code twice on one product
        if (kind === 'carton' && !p.pack_size) {
          problems.push({ row: line, level: 'warning', message: code + ': carton barcode ' + b + ' has no pack size, so a scan can’t be converted to units — left out' });
          return;
        }
        barcodeOwner[key] = code;
        p.barcodes.push({ barcode: b, kind: kind, units: kind === 'carton' ? p.pack_size : 1 });
        nBarcodes++;
      };
      units.forEach(function (b) { add(b, 'unit'); });
      cartons.forEach(function (b) { add(b, 'carton'); });
      if (!p.barcodes.length) problems.push({ row: line, level: 'warning', message: code + ': no barcode — it can only be matched by product code' });

      byCode[code] = { row: line };
      products.push(p);
    }
    return { products: products, problems: problems,
             stats: { rows: rows.length - start, products: products.length, barcodes: nBarcodes, skipped: skipped } };
  }

  function chunk(list, n) {
    var out = [];
    for (var i = 0; i < list.length; i += n) out.push(list.slice(i, i + n));
    return out;
  }

  // ===========================================================================
  // Venue product catalogue (20261027_01): a venue's POS product list, so a
  // scan shows a name. admin.html's Products tab feeds a spreadsheet or CSV
  // through these and sends the result to start/import/finish_catalogue_import.
  // Everything above this line is the superseded receiving import, kept only
  // because receiving.html (behind its wall) still calls it.
  //
  //   sheetRows(XLSX, sheet)          -> string[][]  (every cell as text)
  //   cleanHeader(h)                  -> header with line breaks and runs of spaces collapsed
  //   detectLayout(headers)           -> { layout: 'bepoz', nameCol, groupCol, sizes: [{ nameCol, barcodeCol, n }] }
  //                                      | { layout: 'columns', roles: [...] }
  //   checkBarcode(raw)               -> { barcode, warning? } | { reject } | null (blank)
  //   sizeInfo(sizeName)              -> { kind, units }
  //   buildCatalogue(rows, layout)    -> { products, problems, stats }
  //   problemsCsv(problems)           -> text for "Download the list of problems"
  //
  // New UI text here follows the rule for new screens: no em dashes.
  // ===========================================================================

  // A spreadsheet cell as the text the venue would see, except numbers: a
  // barcode typed into a number cell is shown by Excel as 9.30001E+12, but the
  // stored value still has every digit, so whole numbers are written out in
  // full. A number with a fraction is kept as it is, and then refused as a
  // barcode with the reason (Bepoz once had 23.859310876020066 in one).
  function cellText(cell) {
    if (!cell || cell.v === undefined || cell.v === null) return '';
    if (cell.t === 'n') return String(cell.v);   // whole numbers are written in full up to 21 digits
    if (cell.t === 'b') return cell.v ? 'TRUE' : 'FALSE';
    if (cell.t === 'e') return '';
    if (cell.t === 'd') return cell.w != null ? String(cell.w) : String(cell.v);
    return String(cell.v);
  }
  function sheetRows(XLSX, sheet) {
    if (!sheet || !sheet['!ref']) return [];
    var range = XLSX.utils.decode_range(sheet['!ref']);
    var rows = [];
    for (var r = range.s.r; r <= range.e.r; r++) {
      var row = [];
      for (var c = range.s.c; c <= range.e.c; c++) row.push(cellText(sheet[XLSX.utils.encode_cell({ r: r, c: c })]));
      rows.push(row);
    }
    while (rows.length && rows[rows.length - 1].every(function (x) { return String(x).trim() === ''; })) rows.pop();
    return rows;
  }

  // Bepoz writes "Size1\n Name"; compare headers with that folded away.
  function cleanHeader(h) { return String(h == null ? '' : h).replace(/\s+/g, ' ').trim(); }

  var CATALOGUE_ROLES = ['ignore', 'name', 'item_code', 'group_name', 'barcode', 'pack_barcode', 'carton_barcode', 'carton_units'];
  var CATALOGUE_ROLE_LABELS = {
    ignore: 'Ignore',
    name: 'Product name',
    item_code: 'Product code (PLU)',
    group_name: 'Group or category',
    barcode: 'Barcode (single)',
    pack_barcode: 'Barcode (pack)',
    carton_barcode: 'Barcode (carton)',
    carton_units: 'Units in a carton',
  };

  function guessCatalogueRole(header) {
    var h = norm(cleanHeader(header));
    if (!h) return 'ignore';
    if (/\b(barcode|barcodes|bar code|ean|upc|gtin|apn)\b/.test(h) || /barcode/.test(h)) {
      if (/\b(carton|ctn|case|cs|outer|tray)\b/.test(h)) return 'carton_barcode';
      if (/\b(pack|pk|inner|[0-9]+ ?pk)\b/.test(h)) return 'pack_barcode';
      return 'barcode';
    }
    if (/\b(pack size|units per|qty per|per carton|per case|carton qty|case qty|carton size|case size|ctn qty)\b/.test(h)) return 'carton_units';
    if (/^(product code|item code|stock code|stockcode|code|plu|sku|product id|item id|item no|item number|product number|prod code)$/.test(h)) return 'item_code';
    if (/\b(group|category|department|dept|parent name|class|sub group|subgroup)\b/.test(h)) return 'group_name';
    if (/^(name|product name|item name|description|desc|product|item|product description|item description)$/.test(h)) return 'name';
    return 'ignore';
  }

  // Bepoz's "Product List: Barcodes" export: Name, then SizeN Name / SizeN
  // Barcodes pairs, Parent Name as the group. Anything else is a plain table
  // whose columns the venue confirms on screen.
  function detectLayout(headers) {
    var hs = (headers || []).map(function (h) { return cleanHeader(h).toLowerCase(); });
    var sizes = [];
    for (var n = 1; n <= 12; n++) {
      var nameCol = hs.indexOf('size' + n + ' name'), barcodeCol = hs.indexOf('size' + n + ' barcodes');
      if (barcodeCol === -1) barcodeCol = hs.indexOf('size' + n + ' barcode');
      if (barcodeCol !== -1) sizes.push({ n: n, nameCol: nameCol, barcodeCol: barcodeCol });
    }
    var nameCol = hs.indexOf('name');
    if (sizes.length && nameCol !== -1) {
      return { layout: 'bepoz', nameCol: nameCol, groupCol: hs.indexOf('parent name'), sizes: sizes };
    }
    var roles = headers.map(guessCatalogueRole);
    ['name', 'item_code', 'group_name', 'carton_units'].forEach(function (single) {
      var seen = false;
      roles = roles.map(function (r) { if (r !== single) return r; if (seen) return 'ignore'; seen = true; return r; });
    });
    return { layout: 'columns', roles: roles };
  }

  // GS1 check digit: weights 3, 1, 3, 1… from the digit next to the check
  // digit, leftwards. Same rule as app.html's barcodeDoubt().
  function gs1CheckOk(d) {
    var sum = 0;
    for (var i = d.length - 2, w = 3; i >= 0; i--, w = 4 - w) sum += (d.charCodeAt(i) - 48) * w;
    return (10 - (sum % 10)) % 10 === d.charCodeAt(d.length - 1) - 48;
  }

  // What the venue agreed (27 Oct 2026): codes that can't be a barcode are
  // left out with the reason; codes that are merely unusual go in, with a
  // warning, because venues print their own labels.
  function checkBarcode(raw) {
    var b = String(raw == null ? '' : raw).trim();
    if (!b) return null;
    if (/^[0-9]+(\.[0-9]+)?e[+-]?[0-9]+$/i.test(b)) {
      return { reject: 'looks like Excel turned it into a number (' + b + '). Export the file again with barcodes as text.' };
    }
    if (/^[0-9]*\.[0-9]*$/.test(b) && /[0-9]/.test(b)) return { reject: 'has a decimal point (' + b + '), so it can’t be a barcode' };
    if (/^[0-9]+$/.test(b)) {
      if (b.length > 14) return { reject: 'has ' + b.length + ' digits (' + b + '); a barcode has at most 14' };
      if (b.length < 8) return { barcode: b, warning: 'short in-store code (' + b.length + ' digits)' };
      if (b.length >= 9 && b.length <= 11) return { barcode: b, warning: b.length + ' digits; shop barcodes have 8, 12, 13 or 14' };
      if (!gs1CheckOk(b)) return { barcode: b, warning: 'the last digit fails the barcode check, so a digit may be wrong' };
      return { barcode: b };
    }
    if (b.length > 48) return { reject: 'is too long to be a barcode' };
    return { barcode: b, warning: 'custom code (not all digits)' };
  }

  // What one scan of a size is. Display only: a 4pk is still counted as one
  // 4pk, and the POS converts it on import. "Carton" is 24 (agreed 27 Oct
  // 2026); a bare "Case" has no agreed size yet, so its units stay unknown.
  function sizeInfo(sizeName) {
    var s = String(sizeName || '').toLowerCase().replace(/\s+/g, ' ').trim();
    var m;
    if (!s) return { kind: 'unit', units: 1 };
    if ((m = s.match(/(?:case|carton|ctn|box|outer)\s*(?:of\s*)?([0-9]{1,4})\b/)) || (m = s.match(/\b([0-9]{1,4})\s*(?:x\s*)?(?:case|carton|ctn)\b/))) {
      return { kind: 'carton', units: parseInt(m[1], 10) };
    }
    if ((m = s.match(/\b([0-9]{1,4})\s*(?:pk|pks|pack|packs|pkt)\b/)) || (m = s.match(/\b(?:pk|pack)\s*([0-9]{1,4})\b/))) {
      var n = parseInt(m[1], 10);
      return { kind: n >= 20 ? 'carton' : 'pack', units: n };
    }
    if (/^(carton|ctn)s?$/.test(s)) return { kind: 'carton', units: 24 };
    if (/^(case|cases|box|outer)$/.test(s)) return { kind: 'carton', units: null };
    return { kind: 'unit', units: 1 };
  }

  // rows: string[][] with the header first. layout: from detectLayout(), or
  // { layout: 'columns', roles } as the venue confirmed them.
  //
  // products: [{ row, name, item_code, group_name, barcodes: [{ barcode, size_name, kind, units, warning }] }]
  // problems: [{ row, product, barcode, level: 'error' | 'warning', message }]
  //   error:   that barcode (or row) was left out
  //   warning: imported, with a note the venue should see
  // stats:     rows, products, barcodes, warnings, rejected, duplicates, noBarcode, skipped
  function buildCatalogue(rows, layout) {
    var products = [], problems = [];
    var stats = { rows: 0, products: 0, barcodes: 0, warnings: 0, rejected: 0, duplicates: 0, noBarcode: 0, skipped: 0 };
    var owner = {};          // barcode key -> { name, row }
    var codes = {};          // item code -> row
    var L = layout || {};
    var roles = L.roles || [];
    var colOf = function (role) { return roles.indexOf(role); };
    var nameCol = L.layout === 'bepoz' ? L.nameCol : colOf('name');
    if (nameCol === -1 || nameCol == null) {
      return { products: [], problems: [{ row: 0, level: 'error', message: 'Choose which column is the product name.' }], stats: stats };
    }
    var codeCol = L.layout === 'bepoz' ? -1 : colOf('item_code');
    var groupCol = L.layout === 'bepoz' ? L.groupCol : colOf('group_name');
    var unitsCol = L.layout === 'bepoz' ? -1 : colOf('carton_units');

    for (var i = 1; i < (rows || []).length; i++) {
      var r = rows[i] || [];
      var line = i + 1;   // as a spreadsheet numbers it
      var cell = function (c) { return c == null || c < 0 ? '' : String(r[c] == null ? '' : r[c]).trim(); };
      if (r.every(function (x) { return String(x == null ? '' : x).trim() === ''; })) continue;
      if (/^totals?:?$/i.test(cell(0)) || /^totals?:?$/i.test(cell(nameCol))) continue;   // Bepoz's summary row
      stats.rows++;
      var name = cell(nameCol).replace(/\s+/g, ' ').slice(0, 300);

      // Every barcode on this row, with what it is.
      var cands = [];
      var addCell = function (text, sizeName, kind, units) {
        splitBarcodes(text).forEach(function (raw) { cands.push({ raw: raw, size_name: sizeName, kind: kind, units: units }); });
      };
      if (L.layout === 'bepoz') {
        L.sizes.forEach(function (s) {
          var bc = cell(s.barcodeCol);
          if (!bc) return;
          var sizeName = cell(s.nameCol).replace(/\s+/g, ' ') || null;
          var info = sizeInfo(sizeName);
          addCell(bc, sizeName, info.kind, info.units);
        });
      } else {
        var cartonUnits = parseInt(cell(unitsCol), 10);
        roles.forEach(function (role, c) {
          if (role === 'barcode') addCell(cell(c), null, 'unit', 1);
          else if (role === 'pack_barcode') addCell(cell(c), 'Pack', 'pack', null);
          else if (role === 'carton_barcode') addCell(cell(c), 'Carton', 'carton', cartonUnits >= 1 ? cartonUnits : null);
        });
      }

      if (!name) {
        if (cands.length) { problems.push({ row: line, level: 'error', message: 'no product name, so it was left out' }); stats.skipped++; }
        continue;
      }
      var itemCode = cell(codeCol).slice(0, 100) || null;
      if (itemCode && codes[itemCode]) {
        problems.push({ row: line, product: name, level: 'error', message: 'product code ' + itemCode + ' is already on row ' + codes[itemCode] + ', so this row was left out' });
        stats.skipped++;
        continue;
      }

      var p = { row: line, name: name, item_code: itemCode, group_name: cell(groupCol).slice(0, 200) || null, barcodes: [] };
      var mine = {};
      cands.forEach(function (cnd) {
        var chk = checkBarcode(cnd.raw);
        if (!chk) return;
        if (chk.reject) {
          problems.push({ row: line, product: name, barcode: cnd.raw, level: 'error', message: 'barcode ' + chk.reject + '; left out' });
          stats.rejected++;
          return;
        }
        var key = barcodeKey(chk.barcode);
        if (mine[key]) return;   // the same code twice on one product (e.g. 0724… and 724…)
        if (owner[key]) {
          problems.push({ row: line, product: name, barcode: chk.barcode, level: 'error',
            message: 'barcode ' + chk.barcode + ' is already listed for "' + owner[key].name + '" (row ' + owner[key].row + '), so it stays there' });
          stats.duplicates++;
          return;
        }
        mine[key] = true;
        owner[key] = { name: name, row: line };
        if (chk.warning) {
          problems.push({ row: line, product: name, barcode: chk.barcode, level: 'warning', message: 'barcode ' + chk.barcode + ': ' + chk.warning });
          stats.warnings++;
        }
        p.barcodes.push({ barcode: chk.barcode, size_name: cnd.size_name, kind: cnd.kind, units: cnd.units, warning: chk.warning || null });
      });

      if (!p.barcodes.length) {
        // Cocktails, coffee, wine by the glass: real products with nothing to
        // scan. Counted, not listed one by one.
        stats.noBarcode++;
        continue;
      }
      if (itemCode) codes[itemCode] = line;
      stats.barcodes += p.barcodes.length;
      products.push(p);
    }
    stats.products = products.length;
    return { products: products, problems: problems, stats: stats };
  }

  function csvCell(v) {
    var s = String(v == null ? '' : v);
    return /[",\r\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }
  function problemsCsv(problems) {
    var lines = ['Row,Product,Barcode,Result,Problem'];
    (problems || []).forEach(function (p) {
      lines.push([p.row || '', p.product || '', p.barcode || '', p.level === 'error' ? 'Left out' : 'Imported', p.message].map(csvCell).join(','));
    });
    return lines.join('\r\n') + '\r\n';
  }

  return {
    ROLES: ROLES, ROLE_LABELS: ROLE_LABELS,
    parseCsv: parseCsv, detectDelimiter: detectDelimiter,
    guessRole: guessRole, guessMapping: guessMapping,
    mappingFromSaved: mappingFromSaved, savedFromMapping: savedFromMapping,
    barcodeKey: barcodeKey, buildProducts: buildProducts, chunk: chunk,
    // Venue catalogue
    CATALOGUE_ROLES: CATALOGUE_ROLES, CATALOGUE_ROLE_LABELS: CATALOGUE_ROLE_LABELS,
    sheetRows: sheetRows, cleanHeader: cleanHeader, guessCatalogueRole: guessCatalogueRole,
    detectLayout: detectLayout, gs1CheckOk: gs1CheckOk, checkBarcode: checkBarcode,
    sizeInfo: sizeInfo, buildCatalogue: buildCatalogue, problemsCsv: problemsCsv,
  };
})();
