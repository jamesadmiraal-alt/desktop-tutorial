# Building Barscan's native iOS/Android apps (Capacitor)

Barscan's web app (`app.html`, `index.html`, and friends at the repo root) has
no build step and deploys to GitHub Pages exactly as committed — that's
unchanged. The native iOS/Android apps are a separate Capacitor wrapper
layered on top; this doc is the runbook for it.

## How it fits together

- `package.json` / `node_modules/` — only used for the Capacitor CLI and
  native plugins. Never affects the GitHub Pages deploy.
- `scripts/prepare-native.js` — copies `app.html` → `native-www/index.html`
  (Capacitor's native shell always loads `index.html` from its `webDir`, and
  `index.html` at the repo root has to stay the marketing page for the web
  deploy), plus `config.js`, `supabase.min.js`, `barcode-detector.iife.js`,
  `zxing_reader.wasm`, and the vendored Capacitor runtime files. Run via
  `npm run prepare-native`; regenerated automatically by `npm run sync:android`
  / `npm run sync:ios`. `native-www/` is gitignored — always generated, never
  hand-edited.
- `capacitor.js`, `capacitor-app-plugin.js`, `capacitor-browser-plugin.js`,
  `capacitor-status-bar-plugin.js` — vendored browser builds of
  `@capacitor/core`, `@capacitor/app`, `@capacitor/browser`,
  `@capacitor/status-bar` (same vendoring convention as `supabase.min.js` /
  `barcode-detector.iife.js`; copied from `node_modules/@capacitor/*/dist/`
  after `npm install`). They're loaded by `app.html` itself and are harmless
  on the web deploy too — `Capacitor.isNativePlatform()` is `false` outside a
  native shell, so every native-only code path in `app.html` (guarded on
  `isNative`) is a no-op there.
- `android/`, `ios/` — the actual native platform projects, committed to the
  repo (standard Capacitor convention). Build artifacts under them
  (`android/app/build/`, `ios/App/Pods/`, etc.) are gitignored, not the
  projects themselves.
- `capacitor.config.json` — `appId: "com.barscan.app"` is a **placeholder**.
  Change it to your real reverse-DNS bundle ID before either store
  submission (it has to match what you register in App Store Connect / Play
  Console) — then re-run `npx cap sync` for both platforms.

## What `app.html` does differently when running natively

All guarded by `Capacitor.isNativePlatform()`, no effect on the web build:

- **Upgrade checkout** opens the Stripe Payment Link via `Browser.open()` (an
  in-app SFSafariViewController / Chrome Custom Tab) instead of
  `window.open(..., '_blank')`, which isn't reliable inside a native WebView.
- **Pro-status refresh on resume**: the app never sees the Payment Link's
  `?upgraded=1` https redirect natively (it loads in that separate in-app
  browser tab, not the app's own WebView), so a `resume` listener re-checks
  `is_pro` from Supabase whenever the app comes back to the foreground —
  which is exactly what happens right after the user closes the checkout tab.
- **Android back button** is wired to the same handlers the in-app "‹ Back"
  buttons use (there's no URL-based routing to hook into), and exits the app
  from the top-level views.
- **Camera release on backgrounding**: the scanner stream is stopped when the
  OS backgrounds the app, not just on in-app view navigation.
- **Status bar**: `setOverlaysWebView({ overlay: false })` so it doesn't sit
  on top of the sticky header.

## Building

Prerequisites:
- **Both platforms**: Node.js, then `npm install` at the repo root.
- **Android**: [Android Studio](https://developer.android.com/studio) (bundles
  the SDK) + a JDK. Set `ANDROID_HOME`/`JAVA_HOME` if the CLI needs them.
- **iOS**: a Mac, Xcode, and [CocoaPods](https://cocoapods.org/) (`sudo gem
  install cocoapods` or `brew install cocoapods`). **Cannot be built on
  Windows or Linux** — Xcode is macOS-only.

```sh
npm install

# Android
npm run sync:android      # regenerates native-www/, copies into android/
npm run open:android      # opens android/ in Android Studio
# From Android Studio: let Gradle sync, then Run on a device/emulator.

# iOS (on a Mac)
npm run sync:ios          # regenerates native-www/, copies into ios/
cd ios/App && pod install && cd ../..
npm run open:ios          # opens ios/App/App.xcworkspace in Xcode
# From Xcode: set your signing team, then Run on a device/simulator.
```

Re-run the matching `sync:*` script (which re-runs `prepare-native`
automatically) any time `app.html` or its sibling assets change, before
opening/rebuilding in Xcode or Android Studio.

## What's already done vs. what's still needed

Done (this machine is Windows, without Xcode/CocoaPods or an Android SDK
installed, so this is as far as it goes here):
- `npm install` + `android/` and `ios/` platform projects generated and
  synced with the current `app.html`.
- Camera permission strings added: `NSCameraUsageDescription` in
  `ios/App/App/Info.plist`, `android.permission.CAMERA` (+ an optional
  `<uses-feature>` since the app has a manual-entry fallback for devices
  without a camera) in `android/app/src/main/AndroidManifest.xml`.
- `ios/App` was scaffolded but **`pod install` was skipped** (no CocoaPods on
  this machine) — run it on a Mac before opening the Xcode workspace, or
  `npx cap sync ios` again there, which retries it automatically.

Still needed before either app is store-ready:
1. **Real bundle ID/package name** — replace the `com.barscan.app` placeholder
   in `capacitor.config.json`, then `npx cap sync` both platforms.
2. **App icons & splash screen** — need a real Barscan logo (1024×1024 PNG is
   enough) from you; run `npx @capacitor/assets generate` once you have one.
   The platform projects currently ship Capacitor's default placeholder icon.
3. **Apple Developer / Google Play Console accounts**, signing
   certificates/keystores, App Store Connect / Play Console listings,
   screenshots, and a privacy policy page (Apple requires a URL for this).
4. **`pod install` on a Mac** (see above) before the iOS project will open
   cleanly in Xcode.
5. **App Store review risk, accepted knowingly**: the iOS build keeps the
   same external Stripe Payment Link checkout as Android and the web. Apple's
   guideline 3.1.1 restricts external payment for digital content/subscriptions
   consumed in-app; B2B/productivity tools like Barscan often get an
   exception, but reviewers apply this case by case, so there's a real chance
   of a rejection and a resubmission cycle. This was a deliberate choice to
   keep things simple rather than build In-App Purchase support — revisit if
   Apple pushes back on review.
