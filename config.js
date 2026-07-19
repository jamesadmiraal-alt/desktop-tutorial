// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://vfixdchbkmqryfhirphx.supabase.co',
  supabaseAnonKey: 'sb_publishable_juhiIJWl7qvSj4hL_7JQcA_wEoNVgi6',
  // Where the in-app "Upgrade to Pro" button sends people. Point this at a
  // Stripe Payment Link (or similar) once payments are set up; until then it
  // opens the landing page's pricing section.
  upgradeUrl: ''
};
