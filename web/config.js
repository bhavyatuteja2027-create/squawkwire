// Squawkwire web app — public runtime config.
// These values are CLIENT-SAFE: the anon key only grants access allowed by Row Level
// Security, and the Turnstile SITE key is meant to be public. The service-role key and the
// Stripe secret key must NEVER appear here (worker/server only).
//
// Fill these with your project values, or have your deploy step generate this file from
// SUPABASE_URL / SUPABASE_ANON_KEY / TURNSTILE_SITE_KEY env vars.
window.ES_CONFIG = {
  SUPABASE_URL: "https://YOUR-PROJECT.supabase.co",
  SUPABASE_ANON_KEY: "your-anon-public-key",
  // Cloudflare Turnstile site key. Leave empty to disable the widget (dev).
  TURNSTILE_SITE_KEY: "",
};
