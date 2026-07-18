// Barscan Supabase configuration.
// Get these from your Supabase project: Dashboard -> Project Settings -> API.
// The anon (publishable) key is safe to embed in a frontend — access is
// controlled by Row Level Security (see schema.sql).
window.BARSCAN_CONFIG = {
  supabaseUrl: 'https://YOUR-PROJECT.supabase.co',
  supabaseAnonKey: 'YOUR-ANON-KEY',
  // Where the in-app "Upgrade to Pro" button sends people. Point this at a
  // Stripe Payment Link (or similar) once payments are set up; until then it
  // opens the landing page's pricing section.
  upgradeUrl: ''
};
