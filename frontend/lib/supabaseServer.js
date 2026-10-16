// Server-only Supabase helpers for route handlers.
// The service-role client bypasses RLS — used only in server route handlers, never shipped
// to the browser (no NEXT_PUBLIC prefix on the key).
import { createClient } from '@supabase/supabase-js';

// Normalize to the project origin (tolerate a pasted /rest/v1 suffix or trailing slash).
function normalizeUrl(raw) {
  let u = (raw || '').trim().replace(/\/+$/, '');
  u = u.replace(/\/rest(\/v1)?$/, '');
  return u.replace(/\/+$/, '');
}

export function admin() {
  const url = normalizeUrl(process.env.NEXT_PUBLIC_SUPABASE_URL);
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) throw new Error('SUPABASE url / service role key not set');
  return createClient(url, key, { auth: { persistSession: false } });
}

// Verify the Authorization: Bearer <access_token> header → the authenticated user (or null).
export async function requireUser(request) {
  const h = request.headers.get('authorization') || '';
  const token = h.startsWith('Bearer ') ? h.slice(7) : null;
  if (!token) return null;
  const url = normalizeUrl(process.env.NEXT_PUBLIC_SUPABASE_URL);
  const anon = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  const client = createClient(url, anon, { auth: { persistSession: false } });
  const { data, error } = await client.auth.getUser(token);
  if (error || !data?.user) return null;
  return data.user;
}
