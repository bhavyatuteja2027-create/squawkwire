"""Worker configuration: env vars, source list, polling intervals, tuning knobs."""
import os

def _base_url(raw):
    """Normalize SUPABASE_URL to the project origin. Tolerates a pasted REST URL
    (…supabase.co/rest/v1/) or trailing slashes so we never double the /rest/v1 path."""
    u = (raw or "").strip().rstrip("/")
    for suffix in ("/rest/v1", "/rest"):
        if u.endswith(suffix):
            u = u[: -len(suffix)]
    return u.rstrip("/")


SUPABASE_URL = _base_url(os.environ.get("SUPABASE_URL", ""))
SERVICE_KEY = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
USER_AGENT = os.environ.get("SOURCE_USER_AGENT", "Squawkwire/0.2 (contact: you@example.com)")

# Sentiment: "finbert" (ProsusAI/finbert) or "keyword" (fallback, no ML deps).
SENTIMENT_BACKEND = os.environ.get("SENTIMENT_BACKEND", "keyword").lower()
HF_MODEL_ID = os.environ.get("HF_MODEL_ID", "ProsusAI/finbert")

# Fuzzy clustering similarity threshold (0..1). Matches brief "above 0.9 within 24h".
CLUSTER_THRESHOLD = float(os.environ.get("CLUSTER_THRESHOLD", "0.9"))

# Impact flag threshold on |score| (brief section 6.7). Central-bank sources also flagged.
IMPACT_ABS_SCORE = float(os.environ.get("IMPACT_ABS_SCORE", "0.5"))
IMPACT_SOURCES = {"Federal Reserve", "ECB", "Bank of England", "BLS"}

HTTP_TIMEOUT = int(os.environ.get("HTTP_TIMEOUT", "20"))

# (name, url, default_category, poll_seconds). Mirrors public.sources seed rows.
FEEDS = [
    ("Federal Reserve", "https://www.federalreserve.gov/feeds/press_all.xml", "Central Banks", 120),
    ("ECB", "https://www.ecb.europa.eu/rss/press.html", "Central Banks", 120),
    ("Bank of England", "https://www.bankofengland.co.uk/rss/news", "Central Banks", 120),
    ("SEC", "https://www.sec.gov/news/pressreleases.rss", "Filings", 120),
    ("SEC 8-K", "https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=8-K&count=40&output=atom", "Filings", 120),
    ("BLS", "https://www.bls.gov/feed/bls_latest.rss", "Macro", 300),
    ("CNBC", "https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114", "Equities", 180),
    ("MarketWatch", "https://feeds.content.dowjones.io/public/rss/mw_topstories", "Equities", 180),
]

GDELT_NAME = "GDELT"
GDELT_POLL = 300
GDELT_URL = ("https://api.gdeltproject.org/api/v2/doc/doc?"
             "query=%28economy+OR+inflation+OR+%22central+bank%22+OR+oil+OR+stocks+OR+tariffs%29+sourcelang%3Aenglish"
             "&mode=artlist&maxrecords=50&format=json&sort=datedesc")

# SEC ticker→company map for entity extraction.
SEC_TICKERS_URL = "https://www.sec.gov/files/company_tickers.json"
SEC_TICKERS_REFRESH_SECONDS = int(os.environ.get("SEC_TICKERS_REFRESH_SECONDS", "86400"))


def require_env():
    missing = [k for k, v in (("SUPABASE_URL", SUPABASE_URL), ("SUPABASE_SERVICE_ROLE_KEY", SERVICE_KEY)) if not v]
    if missing:
        raise SystemExit("ERROR: missing env: " + ", ".join(missing))
