'use client';
// Browser Supabase client (singleton). Uses the public URL + anon key — protected by RLS.
import { createBrowserClient } from '@supabase/ssr';

// Normalize to the project origin. Tolerates a pasted REST URL (…supabase.co/rest/v1) or
// trailing slashes, which would otherwise break auth (…/rest/v1/auth/v1/signup).
export function normalizeUrl(raw) {
  let u = (raw || '').trim().replace(/\/+$/, '');
  u = u.replace(/\/rest(\/v1)?$/, '');
  return u.replace(/\/+$/, '');
}

let _client = null;

export function supabaseBrowser() {
  if (_client) return _client;
  _client = createBrowserClient(
    normalizeUrl(process.env.NEXT_PUBLIC_SUPABASE_URL),
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  );
  return _client;
}
