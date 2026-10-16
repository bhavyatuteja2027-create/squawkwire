-- Easy Squawk — Phase 2: fuzzy clustering, entity read access, source health,
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
