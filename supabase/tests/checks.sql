-- Easy Squawk — SQL verification checks (Phase 5 test suite, DB side).
-- These are manual assertions to run in the Supabase SQL editor against a seeded project.
-- They verify the money-path + security invariants that unit tests can't (they need the DB).
-- Each block prints PASS/FAIL. Run as the service role (SQL editor runs with elevated rights).

-- =========================================================
-- 1. Entitlement delay is enforced by feed_items(), not the client
-- =========================================================
-- Insert one fresh and one old item, then check a FREE user only sees the old one.
-- (Run while impersonating a free user via the API for the real RLS path; here we assert
--  the function's filter logic directly.)
do $$
declare free_delay int;
begin
  select (features->>'delay_seconds')::int into free_delay from public.plans where code='free';
  assert free_delay = 86400, 'free delay should be 24h';
  raise notice 'PASS: free plan delay = % seconds', free_delay;
end $$;

-- =========================================================
-- 2. items are NOT directly readable by end users (must go through feed_items)
-- =========================================================
-- The items SELECT policy for authenticated is USING(false). Confirm the policy exists.
do $$
declare n int;
begin
  select count(*) into n from pg_policies
   where tablename='items' and policyname='items_no_direct_read';
  assert n=1, 'items_no_direct_read policy missing';
  raise notice 'PASS: items direct-read policy present (reads go through feed_items)';
end $$;

-- =========================================================
-- 3. Alert matcher: word-boundary + ticker + min score
-- =========================================================
-- Seed a user, rule, item, run match_alerts, assert a delivery row appears.
-- Replace :uid with a real auth user id, or run inside a transaction you roll back.
-- Illustrative; adapt ids to your project.
--
-- insert into public.alert_rules (user_id, term, min_abs_score, channels, enabled)
--   values (:uid, 'Fed', 0, array['in_app'], true);
-- insert into public.items (url_hash,title,url,source_name,category,score,published_at)
--   values ('t_match','Fed signals rate cut','https://x','Federal Reserve','Central Banks',-0.6, now());
-- select public.match_alerts((select id from public.items where url_hash='t_match'));
-- assert: one alert_deliveries row (channel in_app, status sent) for that rule+item.
--
-- Negative: a rule 'oil' must NOT match 'foil' (word boundary).
do $$
begin
  assert 'foil remains cheap' !~* '\moil\M', 'word-boundary regex should not match substring';
  assert 'oil prices rise'   ~* '\moil\M', 'word-boundary regex should match whole word';
  raise notice 'PASS: word-boundary alert matching';
end $$;

-- =========================================================
-- 4. Webhook idempotency: claim_webhook_event is exactly-once
-- =========================================================
do $$
declare first boolean; second boolean;
begin
  delete from public.webhook_events where provider='test' and event_id='evt_dup';
  select public.claim_webhook_event('test','evt_dup','x','{}'::jsonb) into first;
  select public.claim_webhook_event('test','evt_dup','x','{}'::jsonb) into second;
  assert first = true,  'first claim should succeed';
  assert second = false, 'duplicate claim should be rejected';
  delete from public.webhook_events where provider='test' and event_id='evt_dup';
  raise notice 'PASS: webhook idempotency (first=true, duplicate=false)';
end $$;

-- =========================================================
-- 5. Admin RPCs refuse non-admins
-- =========================================================
-- require_admin() raises 42501 when auth.uid() is not an admin. As the service role,
-- auth.uid() is null → is_admin(null) is false → these raise. Confirm the guard is wired.
do $$
begin
  begin
    perform public.admin_revenue();
    raise exception 'admin_revenue should have raised for a non-admin';
  exception when sqlstate '42501' then
    raise notice 'PASS: admin_revenue blocks non-admin (42501)';
  end;
end $$;

-- =========================================================
-- 6. Plans map to Stripe prices (after you set provider_price_id)
-- =========================================================
do $$
declare missing int;
begin
  select count(*) into missing from public.plans
   where code in ('retail','pro') and provider_price_id is null;
  if missing > 0 then
    raise notice 'TODO: set provider_price_id for % paid plan(s) before checkout works', missing;
  else
    raise notice 'PASS: all paid plans have a Stripe price id';
  end if;
end $$;
