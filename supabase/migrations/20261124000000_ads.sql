-- Ads and Ovvas Pro (Advertising & Monetization SRS v1.1).

-- Settings the app reads at startup, without an app update (FR-ADS-10).
-- Anyone may read them; only the dashboard (service role) may change them.
create table public.app_config (
  key text primary key,
  value jsonb not null
);

alter table public.app_config enable row level security;
create policy "read app config" on public.app_config for select to anon, authenticated using (true);
grant select on public.app_config to anon, authenticated;

-- Ads start switched off. To roll out, raise rollout_percent: 5, then 20,
-- then 95. Users with a cohort bucket (0-99) at or above it are the
-- ad-free control group, so stop at 95 to keep about 5% as a baseline.
-- Values outside the allowed ranges are clamped by the app.
insert into public.app_config (key, value) values ('ads', '{
  "enabled": false,
  "rollout_percent": 0,
  "grace_hours": 24,
  "rewarded_daily_limit": 5,
  "reward_hours": 24,
  "reward_views_for_permanent": 10
}');

-- First launch per account, so the 24-hour no-ads grace period does not
-- restart when a signed-in user reinstalls (FR-ADS-06.1).
create table public.account_meta (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  first_seen bigint not null
);

alter table public.account_meta enable row level security;
create policy "own meta" on public.account_meta for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
grant select, insert, update on public.account_meta to authenticated;
