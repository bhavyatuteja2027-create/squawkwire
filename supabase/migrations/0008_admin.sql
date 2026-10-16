-- Easy Squawk — Phase 5: admin flag + admin read RPCs (brief section 12 admin page).
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
