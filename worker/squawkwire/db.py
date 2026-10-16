"""Supabase PostgREST data layer. Calls the service-role RPCs from migration 0004.
Standard library only (urllib)."""
import json, urllib.request, urllib.error

from . import config


def _rpc(fn, payload):
    url = f"{config.SUPABASE_URL}/rest/v1/rpc/{fn}"
    body = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=body, method="POST", headers={
        "apikey": config.SERVICE_KEY,
        "Authorization": f"Bearer {config.SERVICE_KEY}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
        return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        # Surface the real status + body so failures are actionable (404 = RPC missing,
        # 401 = bad key, 400 = arg mismatch) instead of an opaque "HTTPError".
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")[:300]
        except Exception:
            pass
        raise RuntimeError(f"HTTP {e.code} on rpc/{fn}: {detail}") from None


def preflight():
    """Fail fast with a clear diagnosis before ingesting. Checks URL/key/schema.
    Raises SystemExit with a human message on any misconfiguration."""
    url = f"{config.SUPABASE_URL}/rest/v1/sources?select=name&limit=1"
    req = urllib.request.Request(url, headers={
        "apikey": config.SERVICE_KEY,
        "Authorization": f"Bearer {config.SERVICE_KEY}",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            r.read()
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise SystemExit("Preflight 401: SUPABASE_SERVICE_ROLE_KEY is wrong or not the service_role key.")
        if e.code == 404:
            raise SystemExit("Preflight 404: the 'sources' table is missing — run the migrations (0001–0008) first.")
        raise SystemExit(f"Preflight HTTP {e.code}: {e.read().decode('utf-8','replace')[:300]}")
    except urllib.error.URLError as e:
        raise SystemExit(f"Preflight failed to reach {config.SUPABASE_URL}: {e.reason} (check SUPABASE_URL).")
    # Check the RPC the worker depends on actually exists (read-only: PostgREST OpenAPI root
    # lists available /rpc/ functions). Avoids inserting a probe row.
    root = urllib.request.Request(f"{config.SUPABASE_URL}/rest/v1/", headers={
        "apikey": config.SERVICE_KEY, "Authorization": f"Bearer {config.SERVICE_KEY}",
    })
    try:
        with urllib.request.urlopen(root, timeout=15) as r:
            spec = r.read().decode("utf-8", "replace")
        if "/rpc/ingest_item" not in spec:
            raise SystemExit("Preflight: ingest_item() RPC missing — run migration 0004 (and all 0001–0008).")
    except urllib.error.HTTPError:
        pass  # some projects restrict the root; the sources check above already validated access


def ingest_item(row):
    """Insert-or-skip one item with server-side canonical+fuzzy dedupe. Returns item id."""
    return _rpc("ingest_item", {
        "p_url_hash": row["url_hash"],
        "p_title": row["title"],
        "p_url": row["url"],
        "p_source_name": row["source_name"],
        "p_category": row["category"],
        "p_score": row["score"],
        "p_sentiment_probs": row.get("sentiment_probs"),
        "p_impact": row.get("impact", False),
        "p_published_at": row["published_at"],
        "p_cluster_threshold": config.CLUSTER_THRESHOLD,
    })


def add_entity(item_id, ticker, company, score):
    return _rpc("add_entity", {
        "p_item_id": item_id, "p_ticker": ticker,
        "p_company": company, "p_score": score,
    })


def report_source_health(name, ok, note=None):
    try:
        _rpc("report_source_health", {"p_name": name, "p_ok": ok, "p_note": note})
    except Exception:
        pass  # health reporting must never break ingestion


def match_alerts(item_id):
    """Run the alert matcher for a freshly-ingested item. Returns #deliveries created."""
    try:
        return _rpc("match_alerts", {"p_item_id": item_id}) or 0
    except Exception as e:
        print(f"[alerts] match failed for {item_id}: {type(e).__name__}")
        return 0


def claim_pending_emails(limit=50):
    """Return pending email deliveries under each user's hourly rate limit."""
    return _rpc("claim_pending_emails", {"p_limit": limit}) or []


def mark_delivery(delivery_id, status, error=None):
    _rpc("mark_delivery", {"p_id": delivery_id, "p_status": status, "p_error": error})
