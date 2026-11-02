// Gantry Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // After a stocktake is exported with an UNVERIFIED export template, its ⋯
  // sheet asks once "Did this file import cleanly into <POS>?" — the evidence
  // that turns a venue-built (or not-yet-proven Gantry) template into an
  // official one. On until we decide we have enough; set false to stop asking.
  // Answers already given stay in export_template_submissions either way.
  importFeedback: true,
  // Where the in-app upgrade buttons send people, keyed by currency (chosen
  // from the organisation's country — see COUNTRY_CURRENCY in app.html),
  // then by tier ('single' and 'multi' both flat: Team is up to 10 people logged in at
  // the same time since 2 Nov 2026; the old base + per-seat prices are retired), then by billing
  // period ('monthly'/'annual' — see the "Bill annually" toggle in
  // app.html). goUpgrade() falls back to AUD (the home/default currency —
  // see DEFAULT_CURRENCY in app.html) for any currency left with empty
  // links below.
  // symbol/price(s) drive the displayed price (renderUpgradePrices() in
  // app.html) — keep them in sync with the actual Stripe price amounts.
  // TEAM79: the Team links are blank until the new flat Stripe prices and Payment Links
  // exist; blank sends "Choose Team" to the pricing page rather than to a checkout
  // at the old price.
  // Solo links reuse the pre-org-tier product's prices (the original pre-rebrand Pro plan,
  // now named "Gantry Solo" in Stripe — renamed 22 Oct 2026, same price ids).
  upgradeUrls: {
    AUD: {
      single: {
        symbol: 'A$',
        monthly: { link: 'https://buy.stripe.com/test_dRm3cvgdq4dv4mp9csdEs09', price: '29' },
        annual:  { link: 'https://buy.stripe.com/test_cNi3cv1iw5hz8CFgEUdEs08', price: '290' }
      },
      multi: {
        symbol: 'A$',
        monthly: { link: '', price: '79' },   // TEAM79: new Payment Link
        annual:  { link: '', price: '790' }   // TEAM79: new Payment Link
      }
    },
    USD: {
      single: {
        symbol: '$',
        monthly: { link: '', price: '27' },
        annual:  { link: '', price: '270' }
      },
      multi: {
        symbol: '$',
        monthly: { link: '', price: '75' },   // TEAM79: new Payment Link
        annual:  { link: '', price: '750' }   // TEAM79: new Payment Link
      }
    },
    GBP: {
      single: {
        symbol: '£',
        monthly: { link: '', price: '25' },
        annual:  { link: '', price: '250' }
      },
      multi: {
        symbol: '£',
        monthly: { link: '', price: '65' },   // TEAM79: new Payment Link
        annual:  { link: '', price: '650' }   // TEAM79: new Payment Link
      }
    },
    EUR: {
      single: {
        symbol: '€',
        monthly: { link: '', price: '27' },
        annual:  { link: '', price: '270' }
      },
      multi: {
        symbol: '€',
        monthly: { link: '', price: '75' },   // TEAM79: new Payment Link
        annual:  { link: '', price: '750' }   // TEAM79: new Payment Link
      }
    }
  }
};
