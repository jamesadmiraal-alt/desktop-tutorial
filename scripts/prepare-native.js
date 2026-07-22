// Assembles native-www/ (the Capacitor webDir) from the same source files
// used by the GitHub Pages web build. app.html becomes native-www/index.html
// since Capacitor's native shell always loads "index.html" from webDir, and
// index.html at the repo root has to stay the marketing landing page for the
// web deploy. Run via `npm run prepare-native` before every `npx cap sync`.

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..');
const outDir = path.join(root, 'native-www');

const copies = [
  ['config.js', 'config.js'],
  ['supabase.min.js', 'supabase.min.js'],
  ['barcode-detector.iife.js', 'barcode-detector.iife.js'],
  ['zxing_reader.wasm', 'zxing_reader.wasm'],
  ['capacitor.js', 'capacitor.js'],
  ['capacitor-app-plugin.js', 'capacitor-app-plugin.js'],
  ['capacitor-browser-plugin.js', 'capacitor-browser-plugin.js'],
  ['capacitor-status-bar-plugin.js', 'capacitor-status-bar-plugin.js'],
  ['app.html', 'index.html'],
];

fs.rmSync(outDir, { recursive: true, force: true });
fs.mkdirSync(outDir, { recursive: true });

for (const [src, dest] of copies) {
  fs.copyFileSync(path.join(root, src), path.join(outDir, dest));
}

console.log('native-www/ ready (' + copies.length + ' files copied from ' + root + ')');
