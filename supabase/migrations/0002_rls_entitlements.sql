-- Squawkwire — Phase 1 RLS + entitlements + delayed-items RPC (brief sections 8, 9, 10)
-- The free-tier delay is enforced SERVER-SIDE here from day one (brief: "The API enforces
-- it. The front end only hides controls for convenience.") so it is never retrofitted.

-- =========================================================
-- Entitlements  (brief section 9: getEntitlements(userId))
-- =========================================================
-- Returns effective limits for a user from their active/trialing subscription's plan.
-- Falls back to Free defaults if no active paid plan. Plan limits live in plans.features:
--   { "delay_seconds": 86400, "max_widgets": 3, "max_keywords": 3,
--     "channels": ["in_app"], "max_tabs": 1 }

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
    -- Free defaults (also used when the user has no subscription row yet)
    '{"delay_seconds":86400,"max_widgets":3,"max_keywords":3,"max_tabs":1,"channels":["in_app"]}'::jsonb
  );
$$;

-- Convenience: the caller's own entitlements (used by the web app).
create or replace function public.my_entitlements()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public.get_entitlements(auth.uid());
$$;

-- =========================================================
-- Delayed items feed  (brief section 10)
-- =========================================================
-- Paid users (delay_seconds = 0) see everything; Free users only see items older
-- than their delay. Filtering here means the delay cannot be bypassed from the client.
-- Mirrors the GET /items?category=&source=&q=&before=&limit= contract (section 11).

create or replace function public.feed_items(
  p_category text default null,
  p_source   text default null,
  p_q        text default null,
  p_before   timestamptz default null,
  p_limit    integer default 120
)
returns setof public.items
language sql
stable
security definer
set search_path = public
as $$
  select i.*
  from public.items i,
       lateral (select (public.get_entitlements(auth.uid())->>'delay_seconds')::int as d) e
  where i.published_at <= now() - make_interval(secs => coalesce(e.d, 86400))
    and (p_category is null or i.category = p_category)
    and (p_source   is null or i.source_name = p_source)
    and (p_q is null or i.title ilike '%' || p_q || '%')
    and (p_before is null or i.published_at < p_before)
  order by i.published_at desc
  limit least(coalesce(p_limit, 120), 400);
$$;

grant execute on function public.my_entitlements() to authenticated;
grant execute on function public.feed_items(text,text,text,timestamptz,integer) to authenticated;

-- =========================================================
-- Row Level Security
-- =========================================================

-- ---- Reference data: readable by any authenticated user, writable only by service role ----
alter table public.plans   enable row level security;
alter table public.sources enable row level security;
alter table public.items   enable row level security;
alter table public.item_entities enable row level security;

create policy plans_read   on public.plans   for select to authenticated using (true);
create policy sources_read on public.sources for select to authenticated using (true);

-- NOTE on items: direct SELECT is intentionally NOT granted to end users, because a raw
-- table read would bypass the entitlement delay. Clients read the feed via feed_items()
-- (security definer). Realtime for paid users is handled by a scoped publication (below).
-- Service role (worker) bypasses RLS entirely, so inserts from the worker still work.
create policy items_no_direct_read on public.items for select to authenticated using (false);
create policy item_entities_no_direct_read on public.item_entities for select to authenticated using (false);

-- ---- Per-user owned tables: a user can only touch their own rows ----
alter table public.profiles               enable row level security;
alter table public.subscriptions          enable row level security;
alter table public.payments               enable row level security;
alter table public.watch_keywords         enable row level security;
alter table public.dashboards             enable row level security;
alter table public.widgets                enable row level security;
alter table public.alert_rules            enable row level security;
alter table public.alert_deliveries       enable row level security;
alter table public.notification_endpoints enable row level security;
alter table public.audit_log              enable row level security;

create policy profiles_self on public.profiles
  for all to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- subscriptions/payments are written by the webhook (service role); users only read theirs.
create policy subscriptions_read_self on public.subscriptions
  for select to authenticated using (user_id = auth.uid());
create policy payments_read_self on public.payments
  for select to authenticated using (user_id = auth.uid());

create policy watch_keywords_self on public.watch_keywords
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy dashboards_self on public.dashboards
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- widgets belong to a dashboard the user owns
create policy widgets_self on public.widgets
  for all to authenticated
  using (exists (select 1 from public.dashboards d where d.id = widgets.dashboard_id and d.user_id = auth.uid()))
  with check (exists (select 1 from public.dashboards d where d.id = widgets.dashboard_id and d.user_id = auth.uid()));

create policy alert_rules_self on public.alert_rules
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy alert_deliveries_read_self on public.alert_deliveries
  for select to authenticated
  using (exists (select 1 from public.alert_rules r where r.id = alert_deliveries.rule_id and r.user_id = auth.uid()));

create policy notification_endpoints_self on public.notification_endpoints
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy audit_log_read_self on public.audit_log
  for select to authenticated using (user_id = auth.uid());
