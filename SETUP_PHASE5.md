# Easy Squawk — Phase 5: hardening (security, admin, legal, tests)

Security headers + CSP, Cloudflare Turnstile bot protection on auth, an admin page gated by an
`is_admin` flag, legal pages with an in-app disclaimer, and a money-path test suite.

---

## 1. Security headers + CSP

`vercel.json` now sends a locked-down CSP plus HSTS, `X-Frame-Options: DENY`, `nosniff`,
`Referrer-Policy`, and `Permissions-Policy`. The CSP allow-list is intentionally tight:
- `script-src`: self + jsDelivr (supabase-js) + Cloudflare Turnstile.
- `connect-src`: self + `*.supabase.co` (REST) + `wss://*.supabase.co` (Realtime) + Turnstile.
- `frame-src`: Turnstile + `js.stripe.com`. `frame-ancestors 'none'`, `object-src 'none'`.

> `'unsafe-inline'` is allowed for `script-src` because the app ships one inline `<script>`.
> To tighten further, move the inline block to an external `app.js` and drop `'unsafe-inline'`.

## 2. Turnstile (bot protection on auth)

Uses **Supabase's native CAPTCHA**: the client renders the Turnstile widget and passes
`options.captchaToken` to `signUp` / `signInWithPassword`; Supabase verifies it server-side.
Setup:
1. Create a Turnstile widget in Cloudflare → copy the **site key** and **secret**.
2. Supabase → Authentication → Settings → enable **Bot & Abuse Protection (Turnstile)** and
   paste the **secret**.
3. Put the **site key** in `web/config.js` (`TURNSTILE_SITE_KEY`). Empty = widget disabled (dev).

## 3. Admin page

Run migration `0008_admin.sql`. Make yourself admin:
```sql
update public.profiles set is_admin = true where email = 'you@example.com';
```
The **Admin** nav item appears only when `my_is_admin()` is true. It shows revenue (30d),
user counts by plan, and source health (stale sources flagged red). Every admin RPC calls
`require_admin()` internally — a non-admin gets `42501`, so the gate is server-side, not just UI.

## 4. Legal pages

`web/legal/{disclaimer,terms,privacy}.html`, served at `/legal/disclaimer` etc. (rewrite in
`vercel.json`). Linked from the app footer; the disclaimer text ("not investment advice…") shows
on every in-app page. Signup requires a Terms/Privacy **consent checkbox**.

> **These are templates, not legal advice.** Each carries a visible warning. Replace the
> `[COMPANY LEGAL NAME]`, `[JURISDICTION]`, `[CONTACT EMAIL]`, `__DATE__` placeholders and have a
> lawyer review before charging users. The financial-advice licensing question (brief section 15)
> is a legal decision for your jurisdiction — not something code can settle.

## 5. Test suite

```bash
npm test          # JS: Stripe webhook parse + entitlement delay (node --test)
npm run test:py   # Python: categorizer, deduper, keyword scorer, entities (unittest)
```
- **Python** (`worker/tests/test_ingestion.py`, 12 tests): categorization rules + default,
  canonical-URL dedupe (tracking params stripped), keyword scorer bullish/bearish/neutral/bounds,
  entity extraction (cashtags, stopword rejection).
- **JS** (`api/tests/billing.test.js`, 6 tests): Stripe `parseEvent` for every handled event type
  + the free/paid delay gate.
- **SQL** (`supabase/tests/checks.sql`): run in the Supabase SQL editor — asserts the free delay,
  the items no-direct-read policy, word-boundary alert matching, webhook idempotency
  (first=true/duplicate=false), admin RPCs refusing non-admins, and plan→price mapping.

> Node 24 note: run the JS tests with the explicit file path (`node --test api/tests/billing.test.js`),
> not the bare directory.

---

## Phase 5 checklist

- [ ] CSP headers present on responses (check DevTools → Network → Headers); app still loads
      (Supabase REST + Realtime, Stripe redirect, Turnstile widget all work under the CSP).
- [ ] With a Turnstile site key set + Supabase secret configured, signup/login require the
      challenge; a bot without a token is rejected by Supabase.
- [ ] Admin tab shows only for an `is_admin` user; a normal user calling an admin RPC gets 42501.
- [ ] `/legal/disclaimer`, `/legal/terms`, `/legal/privacy` load; footer links work; signup blocks
      without the consent checkbox.
- [ ] `npm test` and `npm run test:py` both pass; `supabase/tests/checks.sql` prints PASS lines.

## Non-code launch blockers (still yours to close)

1. **Data-source terms** — verify redistribution rights for each source, especially CNBC and
   MarketWatch RSS (publisher feeds). Official/open sources (Fed, SEC, BLS, GDELT) are safe.
2. **Financial-advice licensing** — confirm whether offering scored alerts to paying users needs
   registration in your jurisdiction. Get a lawyer's sign-off before charging.
