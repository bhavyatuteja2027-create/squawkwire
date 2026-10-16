"""Ticker / company entity extraction (brief section 6.5).

Loads SEC company_tickers.json (ticker -> company name), then for each headline finds:
  - explicit $TICKER cashtags,
  - bare uppercase tickers that are in the SEC map (reduces false positives),
  - company-name substring matches from the SEC map.

Cached in-process and refreshed daily. Network/parse failure degrades to $TICKER-only.
"""
import re, time

from . import config, parse

# ticker -> company, and a lowercase company -> ticker index for name matching.
_tickers = {}
_companies = []  # list of (lower_name, ticker, company)
_loaded_at = 0.0

_CASHTAG = re.compile(r"\$([A-Za-z]{1,5})\b")
_BARE = re.compile(r"\b([A-Z]{2,5})\b")
# Common all-caps words that look like tickers but aren't companies.
_STOP = {"CEO", "CFO", "GDP", "CPI", "FOMC", "ECB", "BOE", "USA", "EU", "UK", "AI",
         "IPO", "SEC", "FED", "ETF", "OPEC", "USD", "EUR", "GBP", "PMI", "Q1", "Q2", "Q3", "Q4"}


def _load():
    global _tickers, _companies, _loaded_at
    now = time.time()
    if _tickers and now - _loaded_at < config.SEC_TICKERS_REFRESH_SECONDS:
        return
    try:
        import json
        data = json.loads(parse.get(config.SEC_TICKERS_URL))
        t, c = {}, []
        for row in data.values():
            tk = (row.get("ticker") or "").upper()
            nm = (row.get("title") or "").strip()
            if tk and nm:
                t[tk] = nm
                if len(nm) >= 4:
                    c.append((nm.lower(), tk, nm))
        if t:
            _tickers, _companies, _loaded_at = t, c, now
    except Exception as e:
        print(f"[entities] SEC tickers unavailable ({type(e).__name__}); $TICKER-only")
        _loaded_at = now  # don't hammer on failure


def extract(title):
    """Return a list of {ticker, company} for one headline (deduped by ticker)."""
    _load()
    found = {}
    low = title.lower()

    for m in _CASHTAG.finditer(title):
        tk = m.group(1).upper()
        found.setdefault(tk, _tickers.get(tk))

    if _tickers:
        for m in _BARE.finditer(title):
            tk = m.group(1)
            if tk in _STOP:
                continue
            if tk in _tickers:
                found.setdefault(tk, _tickers[tk])

        for lname, tk, name in _companies:
            if lname in low:
                found.setdefault(tk, name)

    return [{"ticker": tk, "company": (nm or tk)} for tk, nm in found.items()]
