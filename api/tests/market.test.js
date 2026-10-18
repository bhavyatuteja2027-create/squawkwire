// Unit tests for marketData.js helpers (pure, no deps).
// Run: node --test api/tests/market.test.js  (from repo root)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SYMBOLS, PERIODS, INTERVALS, isAllowed, buildYahooUrl, parseChart, toCsv } from '../../frontend/lib/marketData.js';

test('isAllowed rejects bad period/interval', () => {
  assert.equal(isAllowed('1y', '1d'), true);
  assert.equal(isAllowed('1y', '1h'), false); // not in INTERVALS
  assert.equal(isAllowed('6h', '1d'), false); // not in PERIODS
});

test('buildYahooUrl encodes ^NSEI correctly', () => {
  const url = buildYahooUrl('^NSEI', '1y', '1d');
  assert.ok(url.includes('%5ENSEI'));
  assert.ok(url.includes('range=1y'));
  assert.ok(url.includes('interval=1d'));
});

test('parseChart skips null bars and adds metadata', () => {
  // Build fixture programmatically to avoid any parser edge cases
  const fixture = {
    chart: {
      result: [{
        timestamp: [1, 2, 3],
        indicators: { quote: [{ open: [10, null, 12], high: [11, 12, 13], low: [9, 10, 11], close: [10.5, 11.5, 12.5], volume: [1000, 2000, 3000] }] }
      }]
    }
  };
  const rows = parseChart(fixture, 'Test', 'USD', 'XYZ');
  assert.equal(rows.length, 2); // middle bar has null open → dropped
  assert.equal(rows[0].symbol, 'Test');
  assert.equal(rows[0].currency, 'USD');
  assert.equal(rows[0].exchange, 'XYZ');
  assert.ok(rows[0].date.match(/^\d{4}-\d{2}-\d{2}$/));
});

test('toCsv quotes/escapes commas, quotes, newlines, and emits CRLF', () => {
  const rows = [
    { symbol: 'Gold', currency: 'USD', exchange: 'CMX', date: '2024-01-01', open: 2000, high: 2010, low: 1995, close: 2005, volume: 5000 },
    { symbol: 'Nifty,50', currency: 'INR', exchange: 'NSI', date: '2024-01-01', open: 22000, high: 22100, low: 21950, close: 22050, volume: 100000 },
  ];
  const csv = toCsv(rows);
  // header
  assert.ok(csv.startsWith('symbol,currency,exchange,date,open,high,low,close,volume\r\n'));
  // first row unquoted
  assert.ok(csv.includes('Gold,USD,CMX,2024-01-01,2000,2010,1995,2005,5000\r\n'));
  // second row: symbol has comma → quoted, and CSV line ends with CRLF
  assert.ok(csv.includes('"Nifty,50",INR,NSI,2024-01-01,22000,22100,21950,22050,100000\r\n'));
  // ends with CRLF
  assert.ok(csv.endsWith('\r\n'));
});

test('SYMBOLS has expected tickers and metadata', () => {
  assert.equal(SYMBOLS.gold.ticker, 'GC=F');
  assert.equal(SYMBOLS.nifty.ticker, '^NSEI');
  assert.equal(SYMBOLS.crude.ticker, 'CL=F');
  assert.ok(SYMBOLS.gold.currency);
  assert.ok(SYMBOLS.nifty.exchange);
});