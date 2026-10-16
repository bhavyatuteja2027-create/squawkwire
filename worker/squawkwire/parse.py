"""Fetching + parsing + categorization. Standard library only."""
import hashlib, json, re, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

from . import config

RULES = [
    ("Crypto", r"bitcoin|crypto|ethereum|stablecoin"),
    ("Commodities", r"\boil\b|crude|opec|gold\b|copper|natural gas|wheat"),
    ("FX", r"dollar|euro\b|yen\b|sterling|currency|forex|\bfx\b"),
    ("Central Banks", r"central bank|interest rate|rate decision|fomc|\bfed\b|ecb|boe\b|powell|lagarde"),
    ("Macro", r"inflation|\bcpi\b|\bgdp\b|payrolls?|unemployment|jobs report|retail sales|\bpmi\b"),
    ("World", r"war|sanction|tariff|election|ceasefire|summit|geopolit"),
]


def get(url, timeout=None):
    req = urllib.request.Request(url, headers={"User-Agent": config.USER_AGENT, "Accept": "*/*"})
    with urllib.request.urlopen(req, timeout=timeout or config.HTTP_TIMEOUT) as r:
        return r.read()


def _local(tag):
    return tag.split("}")[-1]


def _to_ts(s):
    if not s:
        return None
    try:
        return parsedate_to_datetime(s).astimezone(timezone.utc).timestamp()
    except Exception:
        pass
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def parse_feed(raw):
    """Return [(title, link, ts)] from an RSS or Atom document."""
    out = []
    for node in ET.fromstring(raw).iter():
        if _local(node.tag) not in ("item", "entry"):
            continue
        d = {_local(c.tag): c for c in node}
        title = (d["title"].text or "").strip() if "title" in d else ""
        link = ""
        if "link" in d:
            link = d["link"].get("href") or (d["link"].text or "").strip()
        when = ""
        for k in ("pubDate", "updated", "published", "date"):
            if k in d and d[k].text:
                when = d[k].text.strip()
                break
        if title and link:
            out.append((re.sub(r"\s+", " ", title), link, _to_ts(when)))
    return out


def parse_gdelt(raw):
    """Return [(title, link, ts, domain)] from a GDELT DOC 2.0 artlist response."""
    out = []
    for a in json.loads(raw).get("articles", []):
        ts = None
        try:
            ts = datetime.strptime(a["seendate"], "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc).timestamp()
        except Exception:
            pass
        out.append((a.get("title", "").strip(), a.get("url", ""), ts, a.get("domain", "GDELT")))
    return out


def categorize(title, default):
    t = title.lower()
    for cat, rx in RULES:
        if re.search(rx, t):
            return cat
    return default


def canonical(url):
    """Strip tracking params so the same story from different links dedupes by url_hash."""
    try:
        u = urllib.parse.urlsplit(url)
        q = [(k, v) for k, v in urllib.parse.parse_qsl(u.query)
             if not k.lower().startswith("utm_") and k.lower() not in ("fbclid", "gclid")]
        return urllib.parse.urlunsplit((u.scheme, u.netloc, u.path, urllib.parse.urlencode(q), ""))
    except Exception:
        return url


def url_hash(url):
    return hashlib.sha1(canonical(url).encode()).hexdigest()[:12]


def iso(ts):
    return datetime.fromtimestamp(ts, timezone.utc).isoformat()
