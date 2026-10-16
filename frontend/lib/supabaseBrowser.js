'use client';
// Browser Supabase client (singleton). Uses the public URL + anon key — protected by RLS.
import { createBrowserClient } from '@supabase/ssr';

let _client = null;

export function supabaseBrowser() {
  if (_client) return _client;
  _client = createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
  );
  return _client;
}
