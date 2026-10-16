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
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read()
    return json.loads(raw) if raw else None


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
