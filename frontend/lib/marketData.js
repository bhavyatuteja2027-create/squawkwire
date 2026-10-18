// Pure, dependency-free helpers for the market-data export (Gold, Nifty 50, Crude Oil).
// No Next/Node imports so it stays unit-testable (api/tests/market.test.js).

export const SYMBOLS = {
  gold:  { label: 'Gold (COMEX futures)', ticker: 'GC=F',   currency: 'USD', exchange: 'CMX' },   // alt: GOLD.NS
  nifty: { label: 'Nifty 50',             ticker: '^NSEI',  currency: 'INR', exchange: 'NSI' },
  crude: { label: 'Crude Oil (WTI)',      ticker: 'CL=F',   currency: 'USD', exchange: 'NYM' },   // alt: BZ=F (Brent)
};

export const PERIODS   = ['5d', '1mo', '3mo', '6mo', '1y', '2y', '5y', 'max'];
export const INTERVALS = ['1d', '1wk', '1mo'];

export const isAllowed = (p, i) => PERIODS.includes(p) && INTERVALS.includes(i);

export function buildYahooUrl(ticker, period, interval) {
  return `https://query1.finance.yahoo.com/v8/finance/chart/${encodeURIComponent(ticker)}`
       + `?range=${encodeURIComponent(period)}&interval=${encodeURIComponent(interval)}`
       + `&includePrePost=false&events=div%2Csplit`;
}

// Yahoo pads gaps with null — drop incomplete bars.
export function parseChart(json, label, currency, exchange) {
  const r = json?.chart?.result?.[0];
  const ts = r?.timestamp || [];
  const q = r?.indicators?.quote?.[0] || {};
  const rows = [];
  for (let i = 0; i < ts.length; i++) {
    const [o, h, l, c, v] = [q.open?.[i], q.high?.[i], q.low?.[i], q.close?.[i], q.volume?.[i]];
    if (o == null || h == null || l == null || c == null) continue;
    rows.push({ symbol: label, currency, exchange, date: new Date(ts[i] * 1000).toISOString().slice(0, 10),
                open: o, high: h, low: l, close: c, volume: v ?? 0 });
  }
  return rows;
}

const csvCell = (x) => { const s = x == null ? '' : String(x);
  return /[",\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s; };

export function toCsv(rows) {
  const header = ['symbol', 'currency', 'exchange', 'date', 'open', 'high', 'low', 'close', 'volume'];
  return [header.join(',')]
    .concat(rows.map((r) => header.map((k) => csvCell(r[k])).join(',')))
    .join('\r\n') + '\r\n';
}