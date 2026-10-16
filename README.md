# Squawkwire

Real-time financial news terminal. Phase 1 build: Supabase backend + Vercel-hosted
web app + Python ingestion worker.

## Architecture (Phase 1)

```
Data sources ──► Ingestion worker (fetch_news.py)
                    │  (interim: GitHub Actions cron; later: Railway/Fly always-on)
                    ▼ INSERT via Supabase service-role
            ┌──────────────────────────────┐
            │ Supabase Postgres (RLS)       │
            │  items, profiles, plans,      │
            │  subscriptions, watch_keywords│
            │  dashboards, widgets, ...     │
            └───┬───────────────┬───────────┘
      Realtime  │               │  REST / RPC (RLS + entitlement delay)
      (paid)    ▼               ▼
            Browser  ◄──── Vercel (static web app + webhook functions)
```

**Three services, each doing one job:**

| Service | Responsibility |
|---|---|
| **Supabase** | Auth, Postgres + Row Level Security, Realtime, Edge Functions |
| **Vercel** | Hosts the web app (`web/`) + payment webhook functions (later phase) |
| **Railway / Fly** (or interim GitHub Actions) | Runs `worker/fetch_news.py` — the only piece that cannot run on Vercel |

> **Why ingestion is not on Vercel:** Vercel/Edge functions are short-lived (10–60s)
> and stateless — they cannot run a continuous poller or hold the FinBERT model in
> memory. The worker must run on an always-on host.

## Layout

```
supabase/migrations/   SQL migrations (schema, RLS, entitlements, seed)
web/                   Static web app (ported from the original index.html)
worker/                Python ingestion worker (fetch_news.py → Postgres)
vercel.json            Vercel static-hosting config for web/
.env.example           Environment variable names (no secrets committed)
```

## Phase 1 scope

- Section 7 schema as SQL migrations with Row Level Security.
- `getEntitlements()` + a delayed-items RPC so the free-tier delay is enforced
  **server-side from day one** (not retrofitted in the payments phase).
- Frontend reads items from Supabase (auth-gated) with realtime for paid users;
  dashboards/tabs/widgets and keywords move from localStorage to the database.
- `fetch_news.py` writes headlines into Postgres (keyword scoring; FinBERT is Phase 2b).

See `SETUP.md` for setup steps, env vars, and the Phase 1 test checklist.
