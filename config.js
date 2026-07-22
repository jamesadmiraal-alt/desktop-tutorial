// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app upgrade buttons send people, keyed by currency (chosen
  // from the operator's country — see COUNTRY_CURRENCY in app.html). Point
  // these at Stripe Payment Links once payments are set up for that
  // currency; goUpgrade() falls back to AUD (the home/default currency —
  // see DEFAULT_CURRENCY in app.html) for any currency left blank below.
  // symbol/monthlyPrice/annualPrice drive the displayed price (renderUpgradePrices()
  // in app.html) — keep them in sync with the actual Stripe price amounts below.
  // See STRIPE-SETUP.md for how to create the extra Payment Links.
  upgradeUrls: {
    AUD: {
      monthly: 'https://buy.stripe.com/test_dRm3cvgdq4dv4mp9csdEs09',        // Pro Monthly ($29/month AUD)
      annual:  'https://buy.stripe.com/test_cNi3cv1iw5hz8CFgEUdEs08',        // Pro Annual ($290/year AUD)
      symbol: 'A$', monthlyPrice: '29', annualPrice: '290'
    },
    USD: {
      monthly: 'https://buy.stripe.com/test_4gM7sL0esfWdf13agwdEs07',        // Pro Monthly ($27/month USD)
      annual:  'https://buy.stripe.com/test_28E5kDf9mh0hg574WcdEs06',        // Pro Annual ($270/year USD)
      symbol: '$', monthlyPrice: '27', annualPrice: '270'
    },
    GBP: {
      monthly: 'https://buy.stripe.com/test_9B66oH9P2cK15qtgEUdEs05',        // Pro Monthly (£25/month GBP)
      annual:  'https://buy.stripe.com/test_28EeVdaT6aBT1ad4WcdEs04',        // Pro Annual (£250/year GBP)
      symbol: '£', monthlyPrice: '25', annualPrice: '250'
    },
    EUR: {
      monthly: 'https://buy.stripe.com/test_eVqeVd9P2cK17yB3S8dEs03',        // Pro Monthly (€27/month EUR)
      annual:  'https://buy.stripe.com/test_4gM7sL4uI11j1ad60gdEs0a',        // Pro Annual (€270/year EUR)
      symbol: '€', monthlyPrice: '27', annualPrice: '270'
    }
  }
};
