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
  // See STRIPE-SETUP.md for how to create the extra Payment Links.
  upgradeUrls: {
    AUD: {
      monthly: 'https://buy.stripe.com/test_fZu14n5yMeS95qt4WcdEs00',        // Pro Monthly ($29/month AUD)
      annual:  'https://buy.stripe.com/test_cNi3cvgdqfWdcSV0FWdEs01'         // Pro Annual ($290/year AUD — 2 months free)
    },
    USD: { monthly: '', annual: '' },
    GBP: { monthly: '', annual: '' },
    EUR: { monthly: '', annual: '' }
  }
};
