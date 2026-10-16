# Easy Squawk — Phase 4: Stripe billing (checkout + webhooks + entitlements go live)

Hosted Stripe Checkout + billing portal + signature-verified webhooks on Vercel serverless
functions. Access changes **only** when a verified webhook arrives (never on the redirect).
Behind a `PaymentProvider` interface so Razorpay can be added later. Prereq: Phases 1–3.

> **Security:** `STRIPE_SECRET_KEY` and `STRIPE_WEBHOOK_SECRET` are server-only (Vercel env).
> They never appear in `web/`. Verified: no secret references in the client folder.

---

## 1. Stripe dashboard (Test mode)

1. Create two **Products** with recurring **Prices**: Retail ($9.99/mo) and Pro ($49/mo).
2. Copy each price id (`price_...`).
3. Create a webhook endpoint → `https://YOUR-APP.vercel.app/api/webhooks/stripe`, subscribe to:
   `checkout.session.completed`, `customer.subscription.created`,
   `customer.subscription.updated`, `customer.subscription.deleted`,
   `invoice.paid`, `invoice.payment_failed`. Copy the signing secret (`whsec_...`).
4. Enable the **Customer portal** (Settings → Billing → Customer portal).

## 2. Database

Run migrations `0006_stripe_billing.sql` and `0007_stripe_prices.sql`, then map plans to prices:

```sql
update public.plans set provider_price_id = 'price_RETAIL_TEST' where code = 'retail';
update public.plans set provider_price_id = 'price_PRO_TEST'    where code = 'pro';
```

## 3. Vercel

1. Install deps: `npm install` (adds `stripe`, `@supabase/supabase-js`).
2. Project **Environment Variables** (server-side):
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`,
   `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `APP_BASE_URL`.
3. Deploy. `vercel.json` serves `web/` as the site and exposes the `api/` functions:
   - `POST /api/billing/checkout` — `{ plan: "retail"|"pro" }` → `{ url }`
   - `POST /api/billing/portal` → `{ url }`
   - `POST /api/webhooks/stripe` — signature-verified, no auth header.

> The webhook needs the **raw** body; `api/webhooks/stripe.js` sets `bodyParser:false`.

## 4. How entitlements go live

`get_entitlements()` (Phase 1) already reads the active/trialing plan's `features`. So once a
webhook writes the subscription via `upsert_subscription`, the delay drops to 0, more widgets /
keywords / channels unlock — **no frontend change needed**. The billing page reads `my_billing()`
and the dashboard re-reads `my_entitlements()` ~4s after a successful return (webhook lag).

## 5. Phase 4 test checklist (Stripe Test mode)

Use Stripe test cards (`4242 4242 4242 4242` success; `4000 0000 0000 0341` attaches but
fails on charge). Replay webhooks with the Stripe CLI (`stripe listen --forward-to .../api/webhooks/stripe`).

- [ ] **Successful payment**: log in → Billing → Upgrade → pay with 4242 → redirected to
      `?billing=success` → within a few seconds the plan badge flips to `LIVE DATA` and the delay
      banner disappears. `subscriptions` row shows `status=active`, correct `plan_id`.
- [ ] **Access only after webhook**: before the webhook arrives, entitlements are still Free
      (the redirect alone grants nothing).
- [ ] **Failed card**: payment fails → no active paid subscription; user stays Free.
- [ ] **Duplicate webhook**: replay the same event id → handler returns `{duplicate:true}`, no
      double subscription/payment row.
- [ ] **Cancellation**: Manage billing → cancel → `cancel_at_period_end=true`; access remains
      until `current_period_end`, then a `subscription.deleted`/`updated` flips to Free.
- [ ] **Upgrade/downgrade**: switch Retail↔Pro in the portal → `subscription.updated` webhook
      updates `plan_id`; entitlements change accordingly.
- [ ] **Portal gating**: a user with no Stripe customer sees no "Manage billing" button; the
      portal endpoint returns `no_customer`.
- [ ] **Security**: `grep` finds no `sk_`/`whsec_`/service-role key in `web/`; webhook rejects a
      bad signature with 400.

---

## Open follow-ups

- **Past-due grace period** (brief: 3 days then downgrade + email): add a scheduled job that
  checks `status='past_due'` + `current_period_end` age. Currently `past_due` keeps the plan's
  entitlements until Stripe transitions it to `canceled`/`unpaid`.
- **Stripe Tax / invoices**: enable Stripe Tax in the dashboard; invoices come from the portal.
- **Razorpay**: implement a second `PaymentProvider` (same interface) + `/api/webhooks/razorpay`.
- **Annual billing**: add annual prices + a monthly/annual toggle on the billing page.
