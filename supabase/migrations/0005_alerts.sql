-- Easy Squawk — Phase 3: alert matcher, delivery dedupe, rate limits, quiet hours
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
