-- Easy Squawk — Phase 4: Stripe billing (brief section 9).
-- Webhooks drive entitlements. Access changes ONLY when a verified webhook arrives
-- (never on the redirect). All RPCs here are service-role (called by the Vercel webhook
-- function with the service key); none are granted to anon/authenticated.

-- =========================================================
-- Idempotency: claim a webhook event exactly once
-- =========================================================
-- Returns true if THIS call is the first to see (provider, event_id); false if a duplicate.
-- The webhook handler must no-op when this returns false (brief: ignore duplicates).
create or replace function public.claim_webhook_event(
  p_provider text,
  p_event_id text,
  p_type     text,
  p_payload  jsonb
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  inserted boolean;
begin
  insert into public.webhook_events (provider, event_id, type, payload, processed_at)
  values (p_provider, p_event_id, p_type, p_payload, now())
  on conflict (provider, event_id) do nothing;
  get diagnostics inserted = row_count;
  return inserted = 1;
end;
$$;
revoke all on function public.claim_webhook_event(text,text,text,jsonb) from anon, authenticated;

-- Release a claimed event so a retried delivery can reprocess it (called on processing failure).
create or replace function public.release_webhook_event(
  p_provider text,
  p_event_id text
)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.webhook_events where provider = p_provider and event_id = p_event_id;
$$;
revoke all on function public.release_webhook_event(text,text) from anon, authenticated;

-- =========================================================
-- Map a Stripe price id -> plan id
-- =========================================================
create or replace function public.plan_for_price(p_price_id text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select id from public.plans where provider_price_id = p_price_id limit 1;
$$;
revoke all on function public.plan_for_price(text) from anon, authenticated;

-- =========================================================
-- Link a Stripe customer id to a user (set at checkout / first webhook)
-- =========================================================
create or replace function public.link_customer(
  p_user     uuid,
  p_customer text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare free_plan uuid;
begin
  select id into free_plan from public.plans where code = 'free' limit 1;
  -- Ensure a subscription row exists to carry the customer id (user may still be Free).
  insert into public.subscriptions (user_id, plan_id, status, provider, provider_customer_id)
  values (p_user, free_plan, 'active', 'stripe', p_customer)
  on conflict do nothing;

  update public.subscriptions
     set provider = 'stripe', provider_customer_id = p_customer, updated_at = now()
   where user_id = p_user;
end;
$$;
revoke all on function public.link_customer(uuid,text) from anon, authenticated;

-- =========================================================
-- Upsert a subscription from a Stripe subscription object
-- =========================================================
-- Resolves the user by provider_customer_id (set at checkout). Upserts by
-- provider_subscription_id. This is the single source of truth for entitlements.
create or replace function public.upsert_subscription(
  p_customer       text,
  p_subscription   text,
  p_price_id       text,
  p_status         text,
  p_period_end     timestamptz,
  p_cancel_at_end  boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_plan uuid;
  v_free uuid;
begin
  select user_id into v_user from public.subscriptions
    where provider_customer_id = p_customer order by updated_at desc limit 1;
  if v_user is null then
    -- No linked user yet (webhook arrived before link). Nothing safe to do.
    return;
  end if;

  v_plan := public.plan_for_price(p_price_id);
  select id into v_free from public.plans where code = 'free' limit 1;

  -- Canceled / incomplete / unpaid → drop to Free entitlements (keep the row for history).
  if p_status in ('canceled','incomplete_expired','unpaid') or v_plan is null then
    v_plan := v_free;
  end if;

  if exists (select 1 from public.subscriptions where provider_subscription_id = p_subscription) then
    update public.subscriptions
       set plan_id = v_plan, status = p_status, current_period_end = p_period_end,
           cancel_at_period_end = coalesce(p_cancel_at_end, false),
           provider = 'stripe', provider_customer_id = p_customer, updated_at = now()
     where provider_subscription_id = p_subscription;
  else
    -- Attach to the user's existing (customer-linked) row if it has no subscription id yet.
    update public.subscriptions
       set plan_id = v_plan, status = p_status, current_period_end = p_period_end,
           cancel_at_period_end = coalesce(p_cancel_at_end, false),
           provider = 'stripe', provider_subscription_id = p_subscription, updated_at = now()
     where user_id = v_user and provider_subscription_id is null;
    if not found then
      insert into public.subscriptions
        (user_id, plan_id, status, provider, provider_customer_id,
         provider_subscription_id, current_period_end, cancel_at_period_end)
      values
        (v_user, v_plan, p_status, 'stripe', p_customer,
         p_subscription, p_period_end, coalesce(p_cancel_at_end, false));
    end if;
  end if;
end;
$$;
revoke all on function public.upsert_subscription(text,text,text,text,timestamptz,boolean) from anon, authenticated;

-- =========================================================
-- Record a payment (invoice.paid / payment_failed)
-- =========================================================
create or replace function public.record_payment(
  p_customer    text,
  p_payment_id  text,
  p_amount      integer,
  p_currency    text,
  p_status      text,
  p_invoice_url text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_user uuid;
begin
  select user_id into v_user from public.subscriptions
    where provider_customer_id = p_customer order by updated_at desc limit 1;
  if v_user is null then
    return;
  end if;
  -- Idempotent: skip if we already recorded this payment id.
  if p_payment_id is not null and exists (
    select 1 from public.payments where provider = 'stripe' and provider_payment_id = p_payment_id
  ) then
    return;
  end if;
  insert into public.payments
    (user_id, provider, provider_payment_id, amount_cents, currency, status, invoice_url)
  values (v_user, 'stripe', p_payment_id, p_amount, p_currency, p_status, p_invoice_url);
end;
$$;
revoke all on function public.record_payment(text,text,integer,text,text,text) from anon, authenticated;

-- =========================================================
-- User-facing: my billing summary (plan, status, renewal)
-- =========================================================
create or replace function public.my_billing()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object(
       'plan_code', p.code, 'plan_name', p.name, 'status', s.status,
       'current_period_end', s.current_period_end,
       'cancel_at_period_end', s.cancel_at_period_end,
       'has_customer', s.provider_customer_id is not null)
     from public.subscriptions s
     join public.plans p on p.id = s.plan_id
     where s.user_id = auth.uid()
     order by p.price_cents desc limit 1),
    jsonb_build_object('plan_code','free','plan_name','Free','status','active')
  );
$$;
grant execute on function public.my_billing() to authenticated;
