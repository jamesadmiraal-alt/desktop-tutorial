// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app upgrade buttons send people, keyed by currency (chosen
  // from the organisation's country — see COUNTRY_CURRENCY in app.html),
  // then by tier ('single' flat, 'multi' base+per-venue), then by billing
  // period ('monthly'/'annual' — see the "Bill annually" toggle in
  // app.html). goUpgrade() falls back to AUD (the home/default currency —
  // see DEFAULT_CURRENCY in app.html) for any currency left with empty
  // links below.
  // symbol/price(s) drive the displayed price (renderUpgradePrices() in
  // app.html) — keep them in sync with the actual Stripe price amounts.
  // PLACEHOLDER — see STRIPE-SETUP.md's Phase D section for how to create
  // the real products/prices/Payment Links (16 total: 2 tiers x 4
  // currencies x 2 periods) and paste the results in here.
  upgradeUrls: {
    AUD: {
      single: {
        symbol: 'A$',
        monthly: { link: '', price: '29' },
        annual:  { link: '', price: '290' }
      },
      multi: {
        symbol: 'A$',
        monthly: { link: '', basePrice: '59', perVenuePrice: '29' },
        annual:  { link: '', basePrice: '590', perVenuePrice: '290' }
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
        monthly: { link: '', basePrice: '54', perVenuePrice: '27' },
        annual:  { link: '', basePrice: '540', perVenuePrice: '270' }
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
        monthly: { link: '', basePrice: '50', perVenuePrice: '25' },
        annual:  { link: '', basePrice: '500', perVenuePrice: '250' }
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
        monthly: { link: '', basePrice: '54', perVenuePrice: '27' },
        annual:  { link: '', basePrice: '540', perVenuePrice: '270' }
      }
    }
  }
};
