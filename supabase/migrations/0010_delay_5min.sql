-- Squawkwire — change the free-tier delay from 24h (86400s) to 5 minutes (300s).
-- Two places hardcode the free delay: the plans row (0003 seed) and the get_entitlements
-- fallback used when a user has no active subscription row (0002). Update BOTH so every
-- code path yields 300s. Paid tiers stay at 0 (live). Enforcement is server-side in
-- feed_items(), so the client cannot bypass the delay.

-- 1) The free plan row.
update public.plans
set features = jsonb_set(features, '{delay_seconds}', '300')
where code = 'free';

-- 2) The get_entitlements fallback (no-subscription users).
create or replace function public.get_entitlements(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with active as (
    select p.features
    from public.subscriptions s
    join public.plans p on p.id = s.plan_id
    where s.user_id = p_user
      and s.status in ('active','trialing')
    order by p.price_cents desc        -- highest active plan wins
    limit 1
  )
  select coalesce(
    (select features from active),
    '{"delay_seconds":300,"max_widgets":3,"max_keywords":3,"max_tabs":1,"channels":["in_app"]}'::jsonb
  );
$$;
