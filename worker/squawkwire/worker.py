"""Squawkwire always-on ingestion worker (Phase 2).

Continuous loop: each source has its own poll interval. On each tick, sources that are "due"
are fetched, parsed, scored in a batch, and ingested via the server-side ingest_item RPC
(canonical + fuzzy dedupe + cluster assignment). Entities are extracted and upserted.
One failing source never stops the others; failures back off and are reported to source health.

Modes:
  python -m squawkwire.worker            # continuous (Railway/Fly always-on)
  python -m squawkwire.worker --once     # single pass of every source (GitHub Actions / cron)
"""
import sys, time, traceback

from . import config, parse, score, entities, db, email_sender


def _impact(score_val, source_name):
    return abs(score_val) >= config.IMPACT_ABS_SCORE or source_name in config.IMPACT_SOURCES


def _ingest_batch(raw_items, source_name):
    """raw_items: list of (title, link, ts). Score in one batch, then ingest each + entities."""
    if not raw_items:
        return 0
    titles = [t for (t, _l, _ts) in raw_items]
    scored = score.score_batch(titles)
    n = 0
    for (title, link, ts), (sc, probs) in zip(raw_items, scored):
        if not title or not link:
            continue
        row = {
            "url_hash": parse.url_hash(link),
            "title": title[:220],
            "url": link,
            "source_name": source_name,
            "category": parse.categorize(title, _default_cat.get(source_name, "World")),
            "score": sc,
            "sentiment_probs": probs,
            "impact": _impact(sc, source_name),
            "published_at": parse.iso(ts) if ts else parse.iso(time.time()),
        }
        try:
            item_id = db.ingest_item(row)
        except Exception as e:
            print(f"[ingest] {source_name}: {e}")
            continue
        if item_id:
            for ent in entities.extract(title):
                try:
                    db.add_entity(item_id, ent["ticker"], ent["company"], sc)
                except Exception:
                    pass
            # Run the alert matcher now that the item + its entities exist.
            db.match_alerts(item_id)
            n += 1
    return n


# source_name -> default category, built from FEEDS once.
_default_cat = {name: cat for (name, _u, cat, _p) in config.FEEDS}
_default_cat[config.GDELT_NAME] = "World"


def poll_source(name, url, is_gdelt=False):
    """Fetch + ingest one source. Returns (count, ok). Reports health."""
    try:
        raw = parse.get(url)
        if is_gdelt:
            parsed = parse.parse_gdelt(raw)
            # GDELT rows carry their own domain as the source name.
            total = 0
            by_domain = {}
            for title, link, ts, domain in parsed:
                by_domain.setdefault(domain or config.GDELT_NAME, []).append((title, link, ts))
            for domain, rows in by_domain.items():
                total += _ingest_batch(rows, domain)
            db.report_source_health(config.GDELT_NAME, True)
            return total, True
        rows = parse.parse_feed(raw)
        n = _ingest_batch(rows, name)
        db.report_source_health(name, True)
        return n, True
    except Exception as e:
        print(f"[poll] {name}: {type(e).__name__}: {e}")
        db.report_source_health(name, False, f"{type(e).__name__}")
        return 0, False


def run_once():
    """Single pass over every source (cron / GitHub Actions path)."""
    db.preflight()  # fail fast with a clear message if URL/key/migrations are wrong
    total, errors = 0, 0
    for name, url, _cat, _poll in config.FEEDS:
        n, ok = poll_source(name, url)
        total += n
        errors += 0 if ok else 1
    n, ok = poll_source(config.GDELT_NAME, config.GDELT_URL, is_gdelt=True)
    total += n
    errors += 0 if ok else 1
    # Flush any pending email alerts produced by this pass.
    sent, failed = email_sender.process_pending()
    print(f"[once] {total} items ingested, {errors} source error(s), emails sent={sent} failed={failed}")
    # Fail only if everything failed (one broken feed must not fail the job).
    return 0 if errors <= len(config.FEEDS) else 1


def run_forever():
    """Continuous loop with per-source intervals and exponential backoff on failure."""
    db.preflight()  # fail fast on misconfig before the loop
    # schedule: name -> {url, interval, next_due, is_gdelt, fails}
    sched = {}
    for name, url, _cat, poll in config.FEEDS:
        sched[name] = {"url": url, "interval": poll, "next": 0.0, "gdelt": False, "fails": 0}
    sched[config.GDELT_NAME] = {"url": config.GDELT_URL, "interval": config.GDELT_POLL,
                                "next": 0.0, "gdelt": True, "fails": 0}

    print(f"[worker] starting; sentiment backend = {config.SENTIMENT_BACKEND}")
    next_email = 0.0
    while True:
        now = time.time()
        for name, s in sched.items():
            if now < s["next"]:
                continue
            _n, ok = poll_source(name, s["url"], is_gdelt=s["gdelt"])
            if ok:
                s["fails"] = 0
                s["next"] = now + s["interval"]
            else:
                # exponential backoff capped at 30 min
                s["fails"] += 1
                s["next"] = now + min(s["interval"] * (2 ** s["fails"]), 1800)
        # Flush pending email alerts roughly every 20s.
        if now >= next_email:
            try:
                email_sender.process_pending()
            except Exception as e:
                print(f"[email] flush error: {type(e).__name__}")
            next_email = now + 20
        time.sleep(5)


def main():
    config.require_env()
    if "--once" in sys.argv:
        sys.exit(run_once())
    try:
        run_forever()
    except KeyboardInterrupt:
        pass
    except Exception:
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
