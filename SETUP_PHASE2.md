# Easy Squawk — Phase 2: always-on worker + FinBERT + clustering + entities

Phase 2 moves ingestion off the 10-minute GitHub Actions cron onto an **always-on worker**,
adds **FinBERT** sentiment, **pg_trgm fuzzy clustering**, and **SEC ticker entity extraction**.
The keyword scorer remains the fallback. Prereq: Phase 1 is deployed (`SETUP.md`).

---

## 1. Database

Run the new migration:

```
supabase/migrations/0004_clustering_entities.sql
```

It adds service-role RPCs — `ingest_item` (canonical + fuzzy dedupe + cluster assignment in
one place), `match_cluster`, `add_entity`, `report_source_health` — and the
user-facing `feed_entities(item_ids[])` RPC (returns tickers for items past the user's delay).

> `idx_items_title_trgm` (GIN trigram, from migration 0001) backs the similarity search. No
> new index needed.

---

## 2. The worker (now a package)

```
worker/
  easysquawk/
    config.py     env, source list + per-source poll intervals, tuning knobs
    parse.py      fetch, RSS/Atom + GDELT parsing, canonical URL, categorize
    score.py      keyword scorer + FinBERT (batched), unified score_batch()
    entities.py   SEC company_tickers.json + $TICKER extraction
    db.py         PostgREST RPC calls (ingest_item / add_entity / health)
    worker.py     run_forever() (always-on) + run_once() (cron)
  fetch_news.py   thin shim → run_once() (keeps the GitHub Actions path working)
  requirements.txt Dockerfile railway.json fly.toml
```

**Run modes:**
```bash
python -m easysquawk.worker          # continuous, per-source intervals (always-on host)
python -m easysquawk.worker --once   # single pass (cron / GitHub Actions)
```

**Sentiment backend** via `SENTIMENT_BACKEND`:
- `keyword` (default) — no ML deps, standard library only. Good for the interim cron.
- `finbert` — `ProsusAI/finbert`, batched. Needs `requirements.txt` installed (torch +
  transformers). If the model can't load, it automatically falls back to keyword scoring.

---

## 3. Deploy the always-on worker

### Railway
1. New project → Deploy from repo → set root to `worker/` (uses `Dockerfile` + `railway.json`).
2. Variables: `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
   `SOURCE_USER_AGENT`, `SENTIMENT_BACKEND=finbert`.
3. Deploy. Logs should show `[worker] starting; sentiment backend = finbert`.

### Fly.io
```bash
cd worker
fly launch --no-deploy            # uses fly.toml (worker process, no public service)
fly secrets set SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... \
  SOURCE_USER_AGENT="EasySquawk/0.2 (contact: you@example.com)" SENTIMENT_BACKEND=finbert
fly deploy
```

> FinBERT needs ~1GB RAM (set in `fly.toml`). For keyword-only, drop to 256MB and set
> `SENTIMENT_BACKEND=keyword`.

**Once the always-on worker is live, disable the GitHub Actions cron** (delete or disable the
`update-feed` workflow) so you don't double-ingest.

---

## 4. Phase 2 test checklist

**Worker**
- [ ] `SENTIMENT_BACKEND=keyword python -m easysquawk.worker --once` ingests with no ML deps.
- [ ] With `requirements.txt` installed, `SENTIMENT_BACKEND=finbert ... --once` loads the model
      and `items.sentiment_probs` is populated (`{pos,neg,neu}`) for new rows.
- [ ] Killing network to one source: that source backs off, others keep ingesting; the job
      does not crash. `sources.failure_count` increments; `last_success_at` stays for others.
- [ ] Continuous mode: each source re-polls on its own interval (Fed ~120s, BLS ~300s, GDELT ~300s).

**Clustering (dedupe across sources)**
- [ ] Two near-identical headlines from different sources within 24h share the same
      `items.cluster_id` (check: `select title, source_name, cluster_id from items order by cluster_id`).
- [ ] An exact-duplicate URL (even with different `utm_*` params) does not create a second row
      (canonical `url_hash`).

**Entities**
- [ ] A headline with `$NVDA` or a known ticker/company creates `item_entities` rows.
- [ ] The dashboard shows ticker chips under those headlines; the `●` impact marker appears on
      high-impact rows (`|score| >= 0.5` or central-bank sources).

**Delay still enforced (regression)**
- [ ] A Free user still only sees items older than 24h, and `feed_entities` returns nothing for
      items still inside the delay window.

---

## Open follow-ups (into Phase 3)

- Alert matcher (watch keywords → `alert_deliveries`) + email/push — Phase 3. The worker is the
  natural place to run matching right after `ingest_item` (it has the item in hand).
- Per-stock sentiment (score the headline in the context of each extracted entity) — the
  `item_entities.score` column is ready; currently it stores the headline score.
- Economic calendar widget, score-history charts — Phase 2 "later" items.
