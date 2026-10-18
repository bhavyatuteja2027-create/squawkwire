# Squawkwire — Phase 6: Market Data Export (Gold, Nifty 50, Crude Oil)

Adds an authenticated **Data** tab to the terminal that lets logged-in users download historical OHLCV
for Gold, Nifty 50, and Crude Oil as a CSV file.

## What it does

- New **Data** nav item (between Watchlists and Billing).
- UI to pick instruments (Gold / Nifty / Crude), period (5d … max), interval (1d / 1wk / 1mo).
- Click **Download CSV** → authenticated `GET /api/market/download` streams a CSV with columns:
  `symbol, currency, exchange, date, open, high, low, close, volume`.
- CSV is generated server-side (no new npm deps); the route fetches from Yahoo Finance's public chart
  endpoint on demand — nothing is stored in Supabase.

## Endpoint

```
GET /api/market/download?symbols=gold,nifty,crude&period=1y&interval=1d
Authorization: Bearer <supabase access token>
```

Response: `text/csv` attachment `squawkwire-market-YYYY-MM-DD.csv`.

## Source & caveats

The data comes from **Yahoo Finance's unofficial chart API** (the same feed `yfinance` uses):

| Instrument | Yahoo ticker | Exchange | Currency | Type |
|---|---|---|---|---|
| Gold | `GC=F` | CMX (COMEX) | USD | FUTURE |
| Nifty 50 | `^NSEI` | NSI (NSE India) | INR | INDEX |
| Crude Oil | `CL=F` | NYM (NYMEX) | USD | FUTURE |

**Important caveats:**

1. **Unofficial & undocumented.** Yahoo has no public API contract; the endpoint can change, return `429`
   (rate limit), or return `null` bars (which the parser drops). The route degrades gracefully:
   one failing symbol does not block the others.
2. **Delayed quotes.** Yahoo is typically ~15–20 min delayed for some exchanges — not tick-accurate.
3. **Currency/unit mix.** Nifty is in INR; Gold and Crude are in USD. The CSV includes `currency` and
   `exchange` columns so the file is self-describing.
4. **Yahoo's Terms of Use** discourage redistribution of the data. Your app already carries a
   "not investment advice" disclaimer, but if you plan to charge for this export, review the
   licensing implications.
5. **Interval limits:**
   - `1m` / `5m` / `15m` only go back ~7 / 60 days.
   - `1d` / `1wk` / `1mo` work with `max` (full history).
   The UI allows only daily/weekly/monthly to match the "historical / anytime" use case.

## If you need stronger / India-native data

Swap the source in `frontend/lib/marketData.js` + `frontend/app/api/market/download/route.js`:

- **Broker APIs** (Angel One SmartAPI, Dhan, Zerodha Kite): true MCX gold/crude futures + NSE Nifty,
  real-time, but need user broker keys (bigger integration).
- **Official exchange files**: NSE Bhavcopy / MCX settlement — free, authoritative, day-level only.
- **Keyed vendors**: Finnhub, Alpha Vantage, Nasdaq Data Link, FRED — documented but need API keys
  (several are already reserved as env names in `.env.example`).

## Files added/changed

| File | Role |
|---|---|
| `frontend/lib/marketData.js` | Pure helpers: symbol map, param allow-lists, Yahoo URL builder, JSON→rows parser, RFC-4180 CSV writer |
| `frontend/app/api/market/download/route.js` | Auth-gated route; parallel fetch with timeout; streams CSV attachment |
| `frontend/components/Terminal.jsx` | Data nav item + view panel with checkboxes, selects, Download button |
| `api/tests/market.test.js` | Unit tests for the pure helpers (`node --test api/tests/market.test.js`) |
| `package.json` (root) | Added `market.test.js` to the `test` script |

## Test locally

```bash
# 1. Start the Next.js dev server
cd frontend
npm run dev   # http://localhost:3000

# 2. Log in, click the "Data" tab, pick instruments/period/interval, click Download CSV

# 3. Run unit tests from repo root
npm test
```

## Deploy

No new env vars. Deploy the `frontend` folder to Vercel as usual — the route handler is a standard
Next.js App Router route (`runtime = 'nodejs'`, `maxDuration = 30`). The CSP in `middleware.js`
already allows server-to-Yahoo calls; no CSP changes required.