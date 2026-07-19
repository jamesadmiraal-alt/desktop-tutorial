// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app upgrade buttons send people. Point these at Stripe
  // Payment Links (or similar) once payments are set up; until then they
  // open the landing page's pricing section.
  upgradeUrl: 'https://buy.stripe.com/test_fZu14n5yMeS95qt4WcdEs00',        // Pro Monthly ($25/month)
  upgradeUrlAnnual: 'https://buy.stripe.com/test_cNi3cvgdqfWdcSV0FWdEs01'   // Pro Annual ($250/year — 2 months free)
};
