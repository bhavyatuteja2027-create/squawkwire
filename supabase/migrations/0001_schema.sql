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
