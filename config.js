// Gantry Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app upgrade buttons send people, keyed by currency (chosen
  // from the organisation's country — see COUNTRY_CURRENCY in app.html),
  // then by tier ('single' flat, 'multi' base+per-concurrent-seat), then by billing
  // period ('monthly'/'annual' — see the "Bill annually" toggle in
  // app.html). goUpgrade() falls back to AUD (the home/default currency —
  // see DEFAULT_CURRENCY in app.html) for any currency left with empty
  // links below.
  // symbol/price(s) drive the displayed price (renderUpgradePrices() in
  // app.html) — keep them in sync with the actual Stripe price amounts.
  // Single-venue links reused from the pre-org-tier "Barscan Pro" product
  // (renamed to "Barscan Single-venue" — still named "Barscan..." in the
  // live Stripe Dashboard as of the Gantry rebrand, see STRIPE-SETUP.md).
  upgradeUrls: {
    AUD: {
      single: {
        symbol: 'A$',
        monthly: { link: 'https://buy.stripe.com/test_dRm3cvgdq4dv4mp9csdEs09', price: '29' },
        annual:  { link: 'https://buy.stripe.com/test_cNi3cv1iw5hz8CFgEUdEs08', price: '290' }
      },
      multi: {
        symbol: 'A$',
        monthly: { link: 'https://buy.stripe.com/test_5kQ5kDaT625n9GJ88odEs0b', basePrice: '59', perSeatPrice: '29' },
        annual:  { link: 'https://buy.stripe.com/test_6oUeVd6CQ11j2ehdsIdEs0c', basePrice: '590', perSeatPrice: '290' }
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
        monthly: { link: 'https://buy.stripe.com/test_bJecN55yM9xP069coEdEs0d', basePrice: '55', perSeatPrice: '27' },
        annual:  { link: 'https://buy.stripe.com/test_7sYfZhf9m7pH4mpagwdEs0e', basePrice: '550', perSeatPrice: '270' }
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
        monthly: { link: 'https://buy.stripe.com/test_9B6fZh1iw4dv8CFewMdEs0f', basePrice: '49', perSeatPrice: '25' },
        annual:  { link: 'https://buy.stripe.com/test_6oU6oH3qE25n3il74kdEs0g', basePrice: '490', perSeatPrice: '250' }
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
        monthly: { link: 'https://buy.stripe.com/test_6oU4gze5i4dv6ux4WcdEs0h', basePrice: '55', perSeatPrice: '27' },
        annual:  { link: 'https://buy.stripe.com/test_bJebJ15yMh0hf1388odEs0i', basePrice: '550', perSeatPrice: '270' }
      }
    }
  }
};
