-- Squawkwire — Phase 1 fix: default user_id to auth.uid() on user-owned tables.
-- The client inserts dashboards/keywords/alert rules WITHOUT a user_id; the RLS
-- `with check (user_id = auth.uid())` then rejects them. Defaulting the column to the
-- caller's id (the canonical Supabase pattern) makes those inserts satisfy RLS.
-- Tables written only by the service role (subscriptions, payments) are unaffected.

alter table public.dashboards      alter column user_id set default auth.uid();
alter table public.watch_keywords  alter column user_id set default auth.uid();
alter table public.alert_rules     alter column user_id set default auth.uid();
alter table public.notification_endpoints alter column user_id set default auth.uid();
