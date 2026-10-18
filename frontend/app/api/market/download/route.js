// GET /api/market/download?symbols=gold,nifty,crude&period=1y&interval=1d
// Auth: Authorization: Bearer <supabase access token>.
import { requireUser } from '@/lib/supabaseServer';
import { SYMBOLS, isAllowed, buildYahooUrl, parseChart, toCsv } from '@/lib/marketData';

export const runtime = 'nodejs';
export const maxDuration = 30;
const UA = 'Mozilla/5.0 (compatible; Squawkwire/0.1)';

async function fetchSymbol(ticker, label, currency, exchange, period, interval, timeoutMs = 9000) {
  const ctl = new AbortController();
  const t = setTimeout(() => ctl.abort(), timeoutMs);
  try {
    const r = await fetch(buildYahooUrl(ticker, period, interval),
      { headers: { 'User-Agent': UA, Accept: 'application/json' }, signal: ctl.signal, cache: 'no-store' });
    if (!r.ok) throw new Error(`yahoo_${r.status}`);
    return parseChart(await r.json(), label, currency, exchange);
  } finally { clearTimeout(t); }
}

export async function GET(request) {
  const user = await requireUser(request);
  if (!user) return Response.json({ error: 'unauthorized' }, { status: 401 });

  const p = new URL(request.url).searchParams;
  const period = p.get('period') || '1y';
  const interval = p.get('interval') || '1d';
  if (!isAllowed(period, interval)) return Response.json({ error: 'invalid_params' }, { status: 400 });

  const keys = (p.get('symbols') || Object.keys(SYMBOLS).join(',')).split(',')
    .map((k) => k.trim()).filter((k) => SYMBOLS[k]);
  if (!keys.length) return Response.json({ error: 'invalid_symbols' }, { status: 400 });

  const settled = await Promise.allSettled(
    keys.map((k) => {
      const s = SYMBOLS[k];
      return fetchSymbol(s.ticker, s.label, s.currency, s.exchange, period, interval);
    }));
  const rows = settled.flatMap((s) => (s.status === 'fulfilled' ? s.value : [])); // partial OK
  if (!rows.length) return Response.json({ error: 'no_data' }, { status: 502 });

  const stamp = new Date().toISOString().slice(0, 10);
  return new Response(toCsv(rows), { headers: {
    'Content-Type': 'text/csv; charset=utf-8',
    'Content-Disposition': `attachment; filename="squawkwire-market-${stamp}.csv"`,
    'Cache-Control': 'no-store',
  }});
}