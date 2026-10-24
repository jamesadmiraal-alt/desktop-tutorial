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

  return {
    ROLES: ROLES, ROLE_LABELS: ROLE_LABELS,
    parseCsv: parseCsv, detectDelimiter: detectDelimiter,
    guessRole: guessRole, guessMapping: guessMapping,
    mappingFromSaved: mappingFromSaved, savedFromMapping: savedFromMapping,
    barcodeKey: barcodeKey, buildProducts: buildProducts, chunk: chunk,
  };
})();
