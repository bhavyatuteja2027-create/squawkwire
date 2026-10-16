# Squawkwire — Next.js frontend

App Router (Next.js 14) port of the Squawkwire terminal. This **supersedes the old static
`web/` folder and the standalone `api/` functions** — the billing/webhook endpoints now live
inside this app as route handlers.

## Structure

```
frontend/
  app/
    layout.js                 root layout (global CSS + Turnstile script)
    page.js                   renders <Terminal/>
    globals.css               ported design tokens + component styles
    legal/{disclaimer,terms,privacy}/page.js   legal routes (+ shared layout.js)
    api/
      billing/checkout/route.js   POST → Stripe Checkout session
      billing/portal/route.js     POST → Stripe billing portal
      webhooks/stripe/route.js    POST → signature-verified, idempotent webhook
  components/Terminal.jsx     the whole dashboard (client component): auth gate,
                              dashboard tabs/widgets/feed, watchlists, alert rules,
                              billing, admin, realtime, toasts, squawk
  lib/
    supabaseBrowser.js        browser client (public anon key)
    supabaseServer.js         service-role admin client + Bearer-token user verify
    payments.js               Stripe PaymentProvider (Razorpay-ready interface)
  next.config.mjs             security headers + CSP (script-src tight; Next bundles JS)
```

> **Behavior preserved** from the original `index.html`: same dark terminal, tabs/widgets,
> realtime for paid users, keyword/alert highlighting, in-app toasts, spoken squawk, and the
> entitlement/delay model. The native `<dialog>` became a styled overlay; the inline script
> became React state + hooks.

## Run locally

```bash
cd frontend
cp .env.local.example .env.local   # fill NEXT_PUBLIC_* + server keys
npm install
npm run dev                        # http://localhost:3000
```

Public env (browser): `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`,
`NEXT_PUBLIC_TURNSTILE_SITE_KEY`.
Server env (route handlers only): `SUPABASE_SERVICE_ROLE_KEY`, `STRIPE_SECRET_KEY`,
`STRIPE_WEBHOOK_SECRET`, `APP_BASE_URL`.

## Deploy on Vercel

1. New Vercel project → set **Root Directory = `frontend`**. Framework auto-detects Next.js.
2. Add all env vars above (public + server). Server keys must **not** be prefixed `NEXT_PUBLIC_`.
3. Deploy. The Stripe webhook endpoint is `https://YOUR-APP.vercel.app/api/webhooks/stripe`
   (point your Stripe webhook there; the old `/api/webhooks/stripe` from the standalone functions
   is replaced by this route).

## Verified

`npm run build` compiles cleanly (10 routes). Not verified here (needs live infra): auth,
realtime, Stripe, and Turnstile end-to-end — see the phase SETUP docs in the repo root.

## Security notes

- CSP in `next.config.mjs` drops `'unsafe-inline'` for **scripts** (Next bundles app JS); only
  `style-src` keeps it. `connect-src` is limited to Supabase (REST + `wss` realtime) + Turnstile;
  `frame-src` to Turnstile + Stripe; `frame-ancestors 'none'`.
- The service-role and Stripe secret keys are read only in `app/api/**` route handlers — never in
  `components/` or `lib/supabaseBrowser.js`.

## Backend (unchanged)

`supabase/` (migrations 0001–0008) and `worker/` (Python ingestion) are unchanged and shared.
This app talks to the same Supabase project.
