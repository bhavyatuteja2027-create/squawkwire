-- ===== supabase/migrations/0001_schema.sql =====
-- Squawkwire — Phase 1 schema (brief section 7) + indexes (section 13)
-- Postgres / Supabase. UUID PKs, created_at/updated_at, prepared for Row Level Security.
-- RLS policies are enabled in a later migration (0002_rls_entitlements.sql).

create extension if not exists "pgcrypto";   -- gen_random_uuid()
create extension if not exists "pg_trgm";     -- fuzzy title clustering (Phase 2b)

-- ---------- updated_at helper ----------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- =========================================================
-- Accounts / billing
-- =========================================================

-- profiles.id == auth.users.id (Supabase Auth user id)
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  email         text,
  display_name  text,
  timezone      text default 'UTC',
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.plans (
  id                uuid primary key default gen_random_uuid(),
  code              text unique not null,         -- free | retail | pro
  name              text not null,
  price_cents       integer not null default 0,
  currency          text not null default 'usd',
  interval          text not null default 'month',-- month | year
  features          jsonb not null default '{}'::jsonb,
  provider_price_id text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create table if not exists public.subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references public.profiles(id) on delete cascade,
  plan_id                   uuid not null references public.plans(id),
  status                    text not null default 'active',  -- trialing|active|past_due|canceled|incomplete
  provider                  text,                            -- stripe | razorpay
  provider_customer_id      text,
  provider_subscription_id  text,
  current_period_end        timestamptz,
  cancel_at_period_end      boolean not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
create index if not exists idx_subscriptions_user on public.subscriptions(user_id);
create index if not exists idx_subscriptions_active on public.subscriptions(user_id, status);

create table if not exists public.payments (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid not null references public.profiles(id) on delete cascade,
  provider            text,
  provider_payment_id text,
  amount_cents        integer,
  currency            text,
  status              text,
  invoice_url         text,
  created_at          timestamptz not null default now()
);
create index if not exists idx_payments_user on public.payments(user_id);

-- Webhook idempotency (server-only; no user access).
create table if not exists public.webhook_events (
  id           uuid primary key default gen_random_uuid(),
  provider     text not null,
  event_id     text not null,
  type         text,
  payload      jsonb,
  processed_at timestamptz,
  created_at   timestamptz not null default now(),
  unique (provider, event_id)
);

-- =========================================================
-- Ingestion / content
-- =========================================================

create table if not exists public.sources (
  id               uuid primary key default gen_random_uuid(),
  name             text not null,
  url              text,
  kind             text,                 -- official | publisher | open | commercial
  default_category text,
  poll_seconds     integer not null default 300,
  enabled          boolean not null default true,
  last_success_at  timestamptz,
  failure_count    integer not null default 0,
  terms_note       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  unique (name)
);

create table if not exists public.items (
  id               uuid primary key default gen_random_uuid(),
  url_hash         text unique not null,         -- sha1 of canonical url (strip tracking params)
  title            text not null,
  url              text not null,
  source_id        uuid references public.sources(id),
  source_name      text,                         -- denormalized for fast reads / GDELT domains
  category         text,
  score            real default 0,               -- -1..+1
  sentiment_probs  jsonb,                         -- {pos,neg,neu} from FinBERT (Phase 2b)
  impact           boolean not null default false,
  published_at     timestamptz not null default now(),
  ingested_at      timestamptz not null default now(),
  cluster_id       uuid                           -- fuzzy-title cluster (Phase 2b)
);
-- Section 13 indexes: feed ordering, category filter, full-text on title.
create index if not exists idx_items_published on public.items(published_at desc);
create index if not exists idx_items_cat_published on public.items(category, published_at desc);
create index if not exists idx_items_source_published on public.items(source_name, published_at desc);
create index if not exists idx_items_title_fts on public.items using gin (to_tsvector('english', title));
create index if not exists idx_items_title_trgm on public.items using gin (title gin_trgm_ops);

create table if not exists public.item_entities (
  id           uuid primary key default gen_random_uuid(),
  item_id      uuid not null references public.items(id) on delete cascade,
  ticker       text,
  company_name text,
  score        real
);
create index if not exists idx_item_entities_item on public.item_entities(item_id);
create index if not exists idx_item_entities_ticker on public.item_entities(ticker);

-- =========================================================
-- User workspace (dashboards, keywords, alerts)
-- =========================================================

create table if not exists public.watch_keywords (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  term       text not null,
  kind       text not null default 'keyword',  -- keyword | ticker
  created_at timestamptz not null default now(),
  unique (user_id, term)
);
create index if not exists idx_watch_keywords_user on public.watch_keywords(user_id);

create table if not exists public.dashboards (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  name       text not null,
  position   integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists idx_dashboards_user on public.dashboards(user_id, position);

create table if not exists public.widgets (
  id           uuid primary key default gen_random_uuid(),
  dashboard_id uuid not null references public.dashboards(id) on delete cascade,
  title        text not null,
  category     text,
  source_id    uuid references public.sources(id),
  source_name  text,          -- keep the name too; sources is optional at widget level
  keyword      text,
  position     integer not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists idx_widgets_dashboard on public.widgets(dashboard_id, position);

create table if not exists public.alert_rules (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles(id) on delete cascade,
  term          text not null,
  min_abs_score real not null default 0,
  channels      text[] not null default array['in_app']::text[],  -- in_app|email|push|webhook|telegram
  enabled       boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_alert_rules_user on public.alert_rules(user_id, enabled);

create table if not exists public.alert_deliveries (
  id         uuid primary key default gen_random_uuid(),
  rule_id    uuid not null references public.alert_rules(id) on delete cascade,
  item_id    uuid not null references public.items(id) on delete cascade,
  channel    text not null,
  status     text,
  sent_at    timestamptz,
  error      text,
  created_at timestamptz not null default now(),
  unique (rule_id, item_id, channel)   -- dedupe: one alert per item per channel
);

create table if not exists public.notification_endpoints (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  kind        text not null,   -- push | webhook | telegram
  value       text not null,
  verified_at timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists idx_notification_endpoints_user on public.notification_endpoints(user_id);

create table if not exists public.audit_log (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid references public.profiles(id) on delete set null,
  action     text not null,
  metadata   jsonb,
  created_at timestamptz not null default now()
);

-- ---------- updated_at triggers ----------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles','plans','subscriptions','sources','dashboards','widgets','alert_rules'
  ]
  loop
    execute format(
      'drop trigger if exists trg_%1$s_updated on public.%1$s;
       create trigger trg_%1$s_updated before update on public.%1$s
       for each row execute function public.set_updated_at();', t);
  end loop;
end $$;

-- ---------- auto-create a profile + default free subscription on signup ----------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
declare free_plan uuid;
begin
  insert into public.profiles (id, email)
  values (new.id, new.email)
  on conflict (id) do nothing;

  select id into free_plan from public.plans where code = 'free' limit 1;
  if free_plan is not null then
    insert into public.subscriptions (user_id, plan_id, status)
    values (new.id, free_plan, 'active')
    on conflict do nothing;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();


-- ===== supabase/migrations/0002_rls_entitlements.sql =====
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


-- ===== supabase/migrations/0003_seed.sql =====
-- Squawkwire — Phase 1 seed data (brief section 9 plans, section 5 sources)
-- Prices/limits are placeholders from the brief — change freely.
-- Run after 0001/0002. Idempotent (on conflict do nothing / update).

-- ---------- Plans ----------
-- features drives get_entitlements(): delay_seconds, max_widgets, max_keywords,
-- max_tabs, channels. Free = 24h delay; paid = 0 delay (live).
insert into public.plans (code, name, price_cents, currency, interval, features) values
  ('free',   'Free',    0,    'usd', 'month',
     '{"delay_seconds":86400,"max_widgets":3,"max_keywords":3,"max_tabs":1,"channels":["in_app"]}'::jsonb),
  ('retail', 'Retail',  999,  'usd', 'month',
     '{"delay_seconds":0,"max_widgets":12,"max_keywords":25,"max_tabs":5,"channels":["in_app","email"]}'::jsonb),
  ('pro',    'Pro',     4900, 'usd', 'month',
     '{"delay_seconds":0,"max_widgets":999,"max_keywords":999,"max_tabs":999,"channels":["in_app","email","push","webhook","telegram"]}'::jsonb)
on conflict (code) do update
  set name        = excluded.name,
      price_cents = excluded.price_cents,
      features    = excluded.features,
      updated_at  = now();

-- ---------- Sources ----------
-- Mirrors FEEDS in worker/fetch_news.py. kind/terms_note flag which are safe (official/open)
-- vs. which need terms verification before launch (publisher RSS). poll_seconds per section 5.
insert into public.sources (name, url, kind, default_category, poll_seconds, terms_note) values
  ('Federal Reserve', 'https://www.federalreserve.gov/feeds/press_all.xml', 'official', 'Central Banks', 120, 'Official public feed'),
  ('ECB',             'https://www.ecb.europa.eu/rss/press.html',            'official', 'Central Banks', 120, 'Official public feed — verify URL'),
  ('Bank of England', 'https://www.bankofengland.co.uk/rss/news',            'official', 'Central Banks', 120, 'Official public feed — verify URL'),
  ('SEC',             'https://www.sec.gov/news/pressreleases.rss',          'official', 'Filings',        120, 'Needs User-Agent with contact email'),
  ('SEC 8-K',         'https://www.sec.gov/cgi-bin/browse-edgar?action=getcurrent&type=8-K&count=40&output=atom', 'official', 'Filings', 120, 'EDGAR current filings; ~10 req/s fair-access limit'),
  ('BLS',             'https://www.bls.gov/feed/bls_latest.rss',             'official', 'Macro',          300, 'Official public feed'),
  ('CNBC',            'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=100003114', 'publisher', 'Equities', 180, 'PUBLISHER RSS — verify redistribution terms before launch; headline+link only'),
  ('MarketWatch',     'https://feeds.content.dowjones.io/public/rss/mw_topstories', 'publisher', 'Equities', 180, 'PUBLISHER RSS — verify redistribution terms before launch; headline+link only'),
  ('GDELT',           'https://api.gdeltproject.org/api/v2/doc/doc',         'open',     'World',          300, 'Open, no key; returns titles+links')
on conflict (name) do update
  set url = excluded.url, kind = excluded.kind,
      default_category = excluded.default_category,
      poll_seconds = excluded.poll_seconds, terms_note = excluded.terms_note,
      updated_at = now();


-- ===== supabase/migrations/0004_clustering_entities.sql =====
-- Squawkwire — Phase 2: fuzzy clustering, entity read access, source health,
-- and a server-side ingest RPC that collapses duplicate stories (brief section 6).

-- =========================================================
-- Fuzzy-title clustering (brief section 6.3)
-- =========================================================
-- One story from several sources should collapse into one cluster. We detect this with
-- pg_trgm similarity on recent titles. idx_items_title_trgm (from 0001) backs this.
-- Threshold and lookback are configurable via function args.

-- Find the most similar recent item above a threshold (used to assign cluster_id).
create or replace function public.match_cluster(
  p_title     text,
  p_threshold real default 0.9,
  p_hours     int  default 24
)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(i.cluster_id, i.id)
  from public.items i
  where i.published_at > now() - make_interval(hours => p_hours)
    and similarity(i.title, p_title) >= p_threshold
  order by similarity(i.title, p_title) desc, i.published_at desc
  limit 1;
$$;

-- =========================================================
-- Server-side ingest (worker calls this once per item)
-- =========================================================
-- Does: canonical url_hash dedupe (unique), fuzzy cluster assignment, insert-or-skip.
-- Returns the item id (existing or new). Keeps dedupe logic in ONE place (the DB), so the
-- worker stays thin and a future second worker can't race a different implementation.
create or replace function public.ingest_item(
  p_url_hash        text,
  p_title           text,
  p_url             text,
  p_source_name     text,
  p_category        text,
  p_score           real,
  p_sentiment_probs jsonb,
  p_impact          boolean,
  p_published_at    timestamptz,
  p_cluster_threshold real default 0.9
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id      uuid;
  v_cluster uuid;
  v_source  uuid;
begin
  -- Idempotent on canonical url.
  select id into v_id from public.items where url_hash = p_url_hash;
  if v_id is not null then
    return v_id;
  end if;

  v_cluster := public.match_cluster(p_title, p_cluster_threshold, 24);
  select id into v_source from public.sources where name = p_source_name;

  insert into public.items
    (url_hash, title, url, source_id, source_name, category, score,
     sentiment_probs, impact, published_at, cluster_id)
  values
    (p_url_hash, left(p_title, 220), p_url, v_source, p_source_name, p_category, p_score,
     p_sentiment_probs, coalesce(p_impact, false), coalesce(p_published_at, now()),
     coalesce(v_cluster, gen_random_uuid()))
  on conflict (url_hash) do nothing
  returning id into v_id;

  -- If a concurrent insert won the race, fetch the winner.
  if v_id is null then
    select id into v_id from public.items where url_hash = p_url_hash;
  end if;
  return v_id;
end;
$$;

-- Entity upsert (brief section 6.5). Dedupe per (item, ticker).
create unique index if not exists uq_item_entities_item_ticker
  on public.item_entities(item_id, ticker);

create or replace function public.add_entity(
  p_item_id uuid,
  p_ticker  text,
  p_company text,
  p_score   real
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.item_entities (item_id, ticker, company_name, score)
  values (p_item_id, p_ticker, p_company, p_score)
  on conflict (item_id, ticker) do update
    set company_name = excluded.company_name, score = excluded.score;
$$;

-- These RPCs are service-role only (worker). Do NOT grant to anon/authenticated.
revoke all on function public.match_cluster(text,real,int) from anon, authenticated;
revoke all on function public.ingest_item(text,text,text,text,text,real,jsonb,boolean,timestamptz,real) from anon, authenticated;
revoke all on function public.add_entity(uuid,text,text,real) from anon, authenticated;

-- =========================================================
-- Expose per-item entities to the feed (read-only)
-- =========================================================
-- feed_items() returns items; the app can fetch entities for visible items. Allow reading
-- entities only for items the user can already see (i.e. past their delay).
create or replace function public.feed_entities(p_item_ids uuid[])
returns setof public.item_entities
language sql
stable
security definer
set search_path = public
as $$
  select e.*
  from public.item_entities e
  join public.items i on i.id = e.item_id,
       lateral (select (public.get_entitlements(auth.uid())->>'delay_seconds')::int as d) ent
  where e.item_id = any(p_item_ids)
    and i.published_at <= now() - make_interval(secs => coalesce(ent.d, 86400));
$$;
grant execute on function public.feed_entities(uuid[]) to authenticated;

-- =========================================================
-- Source health (brief section 13 reliability)
-- =========================================================
-- Worker reports success/failure per source so /admin/health can alert on stale sources.
create or replace function public.report_source_health(
  p_name    text,
  p_ok      boolean,
  p_note    text default null
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.sources
     set last_success_at = case when p_ok then now() else last_success_at end,
         failure_count   = case when p_ok then 0 else failure_count + 1 end,
         terms_note      = coalesce(p_note, terms_note),
         updated_at      = now()
   where name = p_name;
$$;
revoke all on function public.report_source_health(text,boolean,text) from anon, authenticated;


-- ===== supabase/migrations/0005_alerts.sql =====
-- Squawkwire — Phase 3: alert matcher, delivery dedupe, rate limits, quiet hours
-- (brief section 10). The matcher runs server-side so matching logic lives in ONE place;
-- the worker calls match_alerts(item_id) right after ingest.

-- =========================================================
-- Notification preferences (quiet hours + per-channel rate limits)
-- =========================================================
create table if not exists public.notification_prefs (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  quiet_start        smallint,          -- local hour 0..23 (null = no quiet hours)
  quiet_end          smallint,          -- local hour 0..23
  email_max_per_hour integer not null default 20,   -- brief: no more than 20 emails/hour
  push_max_per_hour  integer not null default 60,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
alter table public.notification_prefs enable row level security;
create policy notification_prefs_self on public.notification_prefs
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

drop trigger if exists trg_notification_prefs_updated on public.notification_prefs;
create trigger trg_notification_prefs_updated before update on public.notification_prefs
  for each row execute function public.set_updated_at();

-- alert_deliveries needs a status lifecycle for the email sender to claim work.
-- status: pending | sent | failed | skipped. 'in_app' rows are created already-sent.
alter table public.alert_deliveries
  add column if not exists payload jsonb;

create index if not exists idx_alert_deliveries_pending
  on public.alert_deliveries(channel, status) where status = 'pending';
create index if not exists idx_alert_deliveries_rule_item
  on public.alert_deliveries(rule_id, item_id);

-- =========================================================
-- Quiet-hours check
-- =========================================================
-- Returns true if the user is currently inside quiet hours (in their profile timezone).
create or replace function public.in_quiet_hours(p_user uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  qs smallint; qe smallint; tz text; h int;
begin
  select np.quiet_start, np.quiet_end into qs, qe
    from public.notification_prefs np where np.user_id = p_user;
  if qs is null or qe is null then
    return false;
  end if;
  select coalesce(p.timezone, 'UTC') into tz from public.profiles p where p.id = p_user;
  h := extract(hour from (now() at time zone coalesce(tz, 'UTC')))::int;
  if qs <= qe then
    return h >= qs and h < qe;         -- same-day window, e.g. 22->23
  else
    return h >= qs or h < qe;          -- overnight window, e.g. 22->7
  end if;
end;
$$;

-- =========================================================
-- Alert matcher  (brief section 10)
-- =========================================================
-- For one freshly-ingested item, find enabled rules that match and create alert_deliveries.
-- Match = word-boundary term in title OR ticker match (entities) AND |score| >= min_abs_score.
-- Channels are intersected with the user's plan entitlement channels. Dedupe via the
-- unique (rule_id, item_id, channel). in_app rows are created 'sent' (the client streams them);
-- email/push/webhook rows are created 'pending' for the sender, but 'skipped' during quiet hours.
create or replace function public.match_alerts(p_item_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  it         public.items%rowtype;
  r          record;
  ch         text;
  allowed    jsonb;
  n          integer := 0;
  is_quiet   boolean;
begin
  select * into it from public.items where id = p_item_id;
  if it.id is null then
    return 0;
  end if;

  for r in
    select ar.id as rule_id, ar.user_id, ar.channels, ar.min_abs_score
    from public.alert_rules ar
    where ar.enabled
      and abs(it.score) >= ar.min_abs_score
      and (
        -- word-boundary term match on the title (case-insensitive)
        it.title ~* ('\m' || regexp_replace(ar.term, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\M')
        -- or ticker match via extracted entities
        or exists (
          select 1 from public.item_entities e
          where e.item_id = it.id and upper(e.ticker) = upper(ar.term)
        )
      )
  loop
    allowed := public.get_entitlements(r.user_id) -> 'channels';
    is_quiet := public.in_quiet_hours(r.user_id);

    for ch in select jsonb_array_elements_text(coalesce(to_jsonb(r.channels), '[]'::jsonb))
    loop
      -- channel must be allowed by the user's plan
      if allowed is null or not (allowed ? ch) then
        continue;
      end if;
      insert into public.alert_deliveries (rule_id, item_id, channel, status, sent_at, payload)
      values (
        r.rule_id, it.id, ch,
        case when ch = 'in_app' then 'sent'
             when is_quiet then 'skipped'
             else 'pending' end,
        case when ch = 'in_app' then now() else null end,
        jsonb_build_object('title', it.title, 'url', it.url, 'source', it.source_name,
                           'category', it.category, 'score', it.score)
      )
      on conflict (rule_id, item_id, channel) do nothing;
      if found then
        n := n + 1;
      end if;
    end loop;
  end loop;
  return n;
end;
$$;
revoke all on function public.match_alerts(uuid) from anon, authenticated;

-- =========================================================
-- Email sender support (service role)
-- =========================================================
-- Claim a batch of pending email deliveries that are under the user's hourly rate limit.
-- Returns rows the sender should attempt; marks nothing (sender updates status after send).
create or replace function public.claim_pending_emails(p_limit integer default 50)
returns table (
  delivery_id uuid, user_id uuid, email text, payload jsonb
)
language sql
security definer
set search_path = public
as $$
  select d.id, ar.user_id, pr.email, d.payload
  from public.alert_deliveries d
  join public.alert_rules ar on ar.id = d.rule_id
  join public.profiles pr    on pr.id = ar.user_id
  where d.channel = 'email' and d.status = 'pending'
    and (
      select count(*) from public.alert_deliveries d2
      join public.alert_rules ar2 on ar2.id = d2.rule_id
      where ar2.user_id = ar.user_id and d2.channel = 'email'
        and d2.status = 'sent' and d2.sent_at > now() - interval '1 hour'
    ) < coalesce((select email_max_per_hour from public.notification_prefs np where np.user_id = ar.user_id), 20)
  order by d.created_at
  limit p_limit;
$$;
revoke all on function public.claim_pending_emails(integer) from anon, authenticated;

create or replace function public.mark_delivery(p_id uuid, p_status text, p_error text default null)
returns void
language sql
security definer
set search_path = public
as $$
  update public.alert_deliveries
     set status = p_status,
         sent_at = case when p_status = 'sent' then now() else sent_at end,
         error = p_error
   where id = p_id;
$$;
revoke all on function public.mark_delivery(uuid,text,text) from anon, authenticated;

-- =========================================================
-- User-facing: recent in-app alerts (for the realtime toast feed)
-- =========================================================
-- The client subscribes to alert_deliveries via Realtime; this RPC backfills recent ones.
-- RLS on alert_deliveries already restricts to the user's own rules (0002), but we add a
-- read helper that joins nothing extra and only returns in_app.
create or replace function public.my_recent_alerts(p_limit integer default 20)
returns setof public.alert_deliveries
language sql
stable
security definer
set search_path = public
as $$
  select d.*
  from public.alert_deliveries d
  join public.alert_rules ar on ar.id = d.rule_id
  where ar.user_id = auth.uid() and d.channel = 'in_app'
  order by d.created_at desc
  limit least(coalesce(p_limit, 20), 100);
$$;
grant execute on function public.my_recent_alerts(integer) to authenticated;


-- ===== supabase/migrations/0006_stripe_billing.sql =====
-- Squawkwire — Phase 4: Stripe billing (brief section 9).
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


-- ===== supabase/migrations/0007_stripe_prices.sql =====
-- Squawkwire — Phase 4: map plans to Stripe price ids.
-- Create the prices in the Stripe dashboard (Test mode) for the Retail and Pro products,
-- then set them here (or via the Supabase dashboard). The checkout function reads
-- plans.provider_price_id. Re-run this with your real price ids.
--
-- Example (replace with your Test-mode price ids, they look like price_...):
--
--   update public.plans set provider_price_id = 'price_RETAIL_TEST' where code = 'retail';
--   update public.plans set provider_price_id = 'price_PRO_TEST'    where code = 'pro';
--
-- Leave this file as documentation; run the two UPDATEs with your actual ids.

-- No-op guard so the migration is safe to run as-is before you have price ids.
do $$ begin
  raise notice 'Set plans.provider_price_id for retail/pro with your Stripe Test price ids.';
end $$;


-- ===== supabase/migrations/0008_admin.sql =====
-- Squawkwire — Phase 5: admin flag + admin read RPCs (brief section 12 admin page).
-- All admin RPCs check is_admin(auth.uid()) and raise if not admin, so a non-admin calling
-- them gets nothing even though they're granted to authenticated.

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

create or replace function public.is_admin(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select is_admin from public.profiles where id = p_user), false);
$$;

-- Guard helper: raise unless the caller is an admin.
create or replace function public.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin(auth.uid()) then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end;
$$;

-- ---------- Source health ----------
create or replace function public.admin_source_health()
returns table (
  name text, kind text, enabled boolean,
  last_success_at timestamptz, failure_count integer,
  minutes_since_success numeric, stale boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_admin();
  return query
    select s.name, s.kind, s.enabled, s.last_success_at, s.failure_count,
           round(extract(epoch from (now() - s.last_success_at)) / 60.0, 1),
           (s.last_success_at is null or s.last_success_at < now() - interval '1 hour')
    from public.sources s
    order by stale desc, s.failure_count desc, s.name;
end;
$$;

-- ---------- Users (counts + recent signups) ----------
create or replace function public.admin_user_stats()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'total_users', (select count(*) from public.profiles),
    'new_7d', (select count(*) from public.profiles where created_at > now() - interval '7 days'),
    'by_plan', (
      select coalesce(jsonb_object_agg(code, cnt), '{}'::jsonb) from (
        select p.code, count(*) cnt
        from public.subscriptions s
        join public.plans p on p.id = s.plan_id
        where s.status in ('active','trialing')
        group by p.code
      ) t
    )
  );
end;
$$;

-- ---------- Revenue (from recorded payments) ----------
create or replace function public.admin_revenue()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_admin();
  return jsonb_build_object(
    'paid_30d_cents', (
      select coalesce(sum(amount_cents), 0) from public.payments
      where status = 'paid' and created_at > now() - interval '30 days'),
    'paid_count_30d', (
      select count(*) from public.payments
      where status = 'paid' and created_at > now() - interval '30 days'),
    'failed_30d', (
      select count(*) from public.payments
      where status = 'failed' and created_at > now() - interval '30 days'),
    'active_subscriptions', (
      select count(*) from public.subscriptions where status in ('active','trialing'))
  );
end;
$$;

-- A simple "am I admin?" the client can call to decide whether to show the Admin tab.
create or replace function public.my_is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.is_admin(auth.uid());
$$;

grant execute on function public.my_is_admin() to authenticated;
grant execute on function public.admin_source_health() to authenticated;
grant execute on function public.admin_user_stats() to authenticated;
grant execute on function public.admin_revenue() to authenticated;
-- require_admin() inside each RPC is the real gate; a non-admin call raises 42501.


-- ===== supabase/migrations/0009_insert_defaults.sql =====
-- Squawkwire — Phase 1 fix: default user_id to auth.uid() on user-owned tables.
-- The client inserts dashboards/keywords/alert rules WITHOUT a user_id; the RLS
-- `with check (user_id = auth.uid())` then rejects them. Defaulting the column to the
-- caller's id (the canonical Supabase pattern) makes those inserts satisfy RLS.
-- Tables written only by the service role (subscriptions, payments) are unaffected.

alter table public.dashboards      alter column user_id set default auth.uid();
alter table public.watch_keywords  alter column user_id set default auth.uid();
alter table public.alert_rules     alter column user_id set default auth.uid();
alter table public.notification_endpoints alter column user_id set default auth.uid();


