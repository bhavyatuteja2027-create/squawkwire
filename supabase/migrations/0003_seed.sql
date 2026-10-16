-- Easy Squawk — Phase 1 seed data (brief section 9 plans, section 5 sources)
-- Prices/limits are placeholders from the brief — change freely.
-- Run after 0001/0002. Idempotent (on conflict do nothing / update).

-- ---------- Plans ----------
-- features drives get_entitlements(): delay_seconds, max_widgets, max_keywords,
-- max_tabs, channels. Free = 24h delay; paid = 0 delay (live).
insert into public.plans (code, name, price_cents, currency, interval, features) values
  ('free',   'Free',    0,    'usd', 'month',
     '{"delay_seconds":86400,"max_widgets":3,"max_keywords":3,"max_tabs":1,"channels":["in_app"]}'::jsonb),
  ('retail', 'Retail',  999,  'usd', 'month',
     '{"delay_seconds":0,"max_widgets":12,"max_keywords":25,"max_tabs":5,"channels":["in_app","email"]}'::jsonb),
  ('pro',    'Pro',     4900, 'usd', 'month',
     '{"delay_seconds":0,"max_widgets":999,"max_keywords":999,"max_tabs":999,"channels":["in_app","email","push","webhook","telegram"]}'::jsonb)
on conflict (code) do update
  set name        = excluded.name,
      price_cents = excluded.price_cents,
      features    = excluded.features,
      updated_at  = now();

-- ---------- Sources ----------
-- Mirrors FEEDS in worker/fetch_news.py. kind/terms_note flag which are safe (official/open)
-- vs. which need terms verification before launch (publisher RSS). poll_seconds per section 5.
insert into public.sources (name, url, kind, default_category, poll_seconds, terms_note) values
  ('Federal Reserve', 'https://www.federalreserve.gov/feeds/press_all.xml', 'official', 'Central Banks', 120, 'Official public feed'),
  ('ECB',             'https://www.ecb.europa.eu/rss/press.html',            'official', 'Central Banks', 120, 'Official public feed — verify URL'),
  ('Bank of England', 'https://www.bankofengland.co.uk/rss/news',            'official', 'Central Banks', 120, 'Official public feed — verify URL'),
  ('SEC',             'https://www.sec.gov/news/pressreleases.rss',          'official', 'Filings',        120, 'Needs User-Agent with contact email'),
  ('SEC 8-K',         'https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=8-K&count=40&output=atom', 'official', 'Filings', 120, 'EDGAR current filings; ~10 req/s fair-access limit'),
  ('BLS',             'https://www.bls.gov/feed/bls_latest.rss',             'official', 'Macro',          300, 'Official public feed'),
  ('CNBC',            'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114', 'publisher', 'Equities', 180, 'PUBLISHER RSS — verify redistribution terms before launch; headline+link only'),
  ('MarketWatch',     'https://feeds.content.dowjones.io/public/rss/mw_topstories', 'publisher', 'Equities', 180, 'PUBLISHER RSS — verify redistribution terms before launch; headline+link only'),
  ('GDELT',           'https://api.gdeltproject.org/api/v2/doc/doc',         'open',     'World',          300, 'Open, no key; returns titles+links')
on conflict (name) do update
  set url = excluded.url, kind = excluded.kind,
      default_category = excluded.default_category,
      poll_seconds = excluded.poll_seconds, terms_note = excluded.terms_note,
      updated_at = now();
