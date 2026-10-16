# Easy Squawk — Phase 1 setup & test checklist

Three services: **Supabase** (backend), **Vercel** (web app host), **GitHub Actions**
(interim ingestion — moves to Railway/Fly in Phase 2).

---

## 1. Supabase project

1. Create a project at [supabase.com](https://supabase.com) → note the **Project URL** and
   the **anon** and **service_role** keys from *Project Settings → API*.
2. Run the migrations in order (SQL Editor, or `supabase db push` with the CLI):
   1. `supabase/migrations/0001_schema.sql`
   2. `supabase/migrations/0002_rls_entitlements.sql`
   3. `supabase/migrations/0003_seed.sql`
3. **Auth settings** (*Authentication → Providers / Settings*):
   - Email provider **on**. Keep **Confirm email** on (brief requires verification).
   - Add your Vercel URL + `http://localhost:*` to *Redirect URLs* / *Site URL*.
4. **Realtime**: enable Realtime on the `items` table (*Database → Replication* → add
   `public.items` to the `supabase_realtime` publication). Only paid clients subscribe.

> The `items` table is **not** directly readable by end users (RLS returns nothing); clients
> read through the `feed_items()` RPC so the free-tier delay can't be bypassed. The worker
> uses the **service_role** key, which bypasses RLS, so inserts still work.

---

## 2. Web app on Vercel

1. Edit `web/config.js` and set `SUPABASE_URL` + `SUPABASE_ANON_KEY` (these are public /
   client-safe — protected by RLS).
2. Deploy: point Vercel at the repo. `vercel.json` serves the `web/` folder statically with
   security headers. No build step.
   - Local test: `npx serve web` (or any static server) and open the printed URL.

> **Never** put the service_role key in `web/` or `config.js`. It belongs only to the worker
> / future server functions.

---

## 3. Ingestion (interim: GitHub Actions)

Set repo **Secrets** (*Settings → Secrets and variables → Actions*):

| Secret | Value |
|---|---|
| `SUPABASE_URL` | your project URL |
| `SUPABASE_SERVICE_ROLE_KEY` | service_role key (secret) |
| `SOURCE_USER_AGENT` | `EasySquawk/0.1 (contact: you@example.com)` |

`.github/workflows/update.yml` runs `worker/fetch_news.py` every 10 minutes and upserts into
`public.items`. Trigger once manually via **Actions → update-feed → Run workflow**.

Run locally to seed data immediately:

```bash
export SUPABASE_URL=https://YOUR-PROJECT.supabase.co
export SUPABASE_SERVICE_ROLE_KEY=your-service-role-key
export SOURCE_USER_AGENT="EasySquawk/0.1 (contact: you@example.com)"
python3 worker/fetch_news.py
```

Expected: `N items upserted, M source errors: [...]`.

---

## 4. Environment variables (names)

See `.env.example`. Phase 1 uses only: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`SUPABASE_SERVICE_ROLE_KEY`, `SOURCE_USER_AGENT`. The rest (Stripe/Razorpay/email/push) are
reserved for later phases.

---

## 5. Phase 1 test checklist

**Auth**
- [ ] Visiting the app while logged out shows the login gate.
- [ ] Sign up with a <10-char password is rejected client-side.
- [ ] Sign up with a valid password shows the "check your email" message; the user appears in
      Supabase *Authentication → Users* (unconfirmed).
- [ ] After email confirmation, log in succeeds and the terminal loads.
- [ ] Wrong password shows a generic "Invalid email or password" (never reveals which field).
- [ ] Log out returns to the gate and clears the feed.

**Data + entitlements (the core Phase 1 guarantee)**
- [ ] After the worker runs, headlines appear in widgets.
- [ ] A **Free** user sees the `OPEN DATA` badge, the 24h-delay upsell banner, and widget
      badges read `24h delay`. Newest visible headline is ≥24h old.
- [ ] Temporarily set a user's subscription to the `pro` plan (update `subscriptions.plan_id`
      in Supabase) → reload → badge reads `LIVE DATA`, banner gone, recent headlines visible.
- [ ] **Delay cannot be bypassed:** as a Free user, calling `items` directly returns nothing
      (RLS); only `feed_items()` returns rows, and only delayed ones.

**Workspace persists to the account (not localStorage)**
- [ ] Add a tab / widget / keyword → reload → still there.
- [ ] Log in from a different browser → same tabs, widgets, keywords appear.
- [ ] Free plan caps enforced: adding a 4th widget / 2nd tab / 4th keyword is blocked.

**Realtime (paid)**
- [ ] As a Pro user with the app open, run the worker → a new headline appears within a few
      seconds without manual reload.

**Safety**
- [ ] Feed text renders via `textContent` (no HTML injection); links are `http(s)` only and
      open with `rel="noopener noreferrer"`.
- [ ] `web/config.js` contains only the anon key — no service_role key anywhere in `web/`.

---

## What's intentionally NOT in Phase 1

FinBERT sentiment + fuzzy clustering (Phase 2b), alert matcher + email/push (Phase 3),
payments/checkout/webhooks (Phase 4), the always-on Railway worker (Phase 2a). The schema,
entitlements and delay are already wired so these slot in without rework.
