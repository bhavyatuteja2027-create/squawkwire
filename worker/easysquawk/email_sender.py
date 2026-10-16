"""Email alert sender (brief section 10). Claims pending email deliveries (already filtered
by the DB for per-user hourly rate limit, and quiet-hours rows are created 'skipped' not
'pending'), sends via Resend, and marks each delivery sent/failed. Standard library only.

Env:
  EMAIL_API_KEY   Resend API key (re_...)
  EMAIL_FROM      verified sender, e.g. "Easy Squawk <alerts@yourdomain.com>"
  APP_BASE_URL    optional, used for a link back to the terminal
"""
import json, os, urllib.request

from . import db

RESEND_URL = "https://api.resend.com/emails"
API_KEY = os.environ.get("EMAIL_API_KEY", "")
FROM = os.environ.get("EMAIL_FROM", "Easy Squawk <alerts@example.com>")
APP_BASE_URL = os.environ.get("APP_BASE_URL", "")


def _esc(s):
    return (str(s or "").replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def _html(p):
    title, url, source = _esc(p.get("title")), p.get("url", "#"), _esc(p.get("source"))
    cat, score = _esc(p.get("category")), p.get("score", 0)
    safe_url = url if isinstance(url, str) and url[:4] == "http" else "#"
    dir_txt = "Bullish" if score > 0.15 else "Bearish" if score < -0.15 else "Neutral"
    foot = (f'<p style="color:#8A94A8;font-size:12px">Open your terminal: '
            f'<a href="{_esc(APP_BASE_URL)}">{_esc(APP_BASE_URL)}</a></p>') if APP_BASE_URL else ""
    return (f'<div style="font-family:system-ui,sans-serif;max-width:560px">'
            f'<p style="color:#2FA8FF;font-weight:700;margin:0 0 4px">Easy Squawk alert</p>'
            f'<h2 style="margin:0 0 8px"><a href="{_esc(safe_url)}" style="color:#0E1117;text-decoration:none">{title}</a></h2>'
            f'<p style="color:#8A94A8;margin:0 0 12px">{source} &middot; {cat} &middot; {dir_txt} ({score})</p>'
            f'<p><a href="{_esc(safe_url)}" style="background:#2FA8FF;color:#04121F;padding:8px 14px;'
            f'border-radius:8px;text-decoration:none;font-weight:700">Read headline</a></p>'
            f'{foot}'
            f'<p style="color:#8A94A8;font-size:11px;margin-top:16px">Automated analysis for '
            f'information only, not investment advice.</p></div>')


def _send(to, subject, html):
    body = json.dumps({"from": FROM, "to": [to], "subject": subject, "html": html}).encode()
    req = urllib.request.Request(RESEND_URL, data=body, method="POST", headers={
        "Authorization": f"Bearer {API_KEY}",
        "Content-Type": "application/json",
    })
    with urllib.request.urlopen(req, timeout=20) as r:
        if r.status not in (200, 201):
            raise RuntimeError(f"Resend {r.status}")


def process_pending(limit=50):
    """Claim and send pending email alerts. Returns (sent, failed)."""
    if not API_KEY:
        return (0, 0)  # email disabled; deliveries stay pending until configured
    rows = db.claim_pending_emails(limit)
    sent = failed = 0
    for row in rows:
        did, email, payload = row["delivery_id"], row.get("email"), row.get("payload") or {}
        if not email:
            db.mark_delivery(did, "failed", "no email on profile")
            failed += 1
            continue
        subject = f"🔔 {payload.get('title', 'New alert')}"[:120]
        try:
            _send(email, subject, _html(payload))
            db.mark_delivery(did, "sent")
            sent += 1
        except Exception as e:
            db.mark_delivery(did, "failed", f"{type(e).__name__}")
            failed += 1
    return (sent, failed)
