// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app upgrade buttons send people, keyed by currency (chosen
  // from the organisation's country — see COUNTRY_CURRENCY in app.html) and
  // then by tier ('single' flat, 'multi' base+per-venue). goUpgrade() falls
  // back to AUD (the home/default currency — see DEFAULT_CURRENCY in
  // app.html) for any currency left with empty links below.
  // symbol/price(s) drive the displayed price (renderUpgradePrices() in
  // app.html) — keep them in sync with the actual Stripe price amounts.
  // PLACEHOLDER — see STRIPE-SETUP.md's Phase D section for how to create
  // the real products/prices/Payment Links and paste the results in here.
  upgradeUrls: {
    AUD: {
      single: { link: '', symbol: 'A$', price: '29' },
      multi:  { link: '', symbol: 'A$', basePrice: '59', perVenuePrice: '29' }
    },
    USD: {
      single: { link: '', symbol: '$', price: '27' },
      multi:  { link: '', symbol: '$', basePrice: '54', perVenuePrice: '27' }
    },
    GBP: {
      single: { link: '', symbol: '£', price: '25' },
      multi:  { link: '', symbol: '£', basePrice: '50', perVenuePrice: '25' }
    },
    EUR: {
      single: { link: '', symbol: '€', price: '27' },
      multi:  { link: '', symbol: '€', basePrice: '54', perVenuePrice: '27' }
    }
  }
};
