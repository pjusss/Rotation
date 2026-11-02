-- Play history: every play Rotation sees is stored, so listening time, play counts
-- and streaks build up over time. Spotify itself only shares the last 50 plays.

create extension if not exists pg_net;
create extension if not exists pg_cron;

create table public.tracks (
  id text primary key,
  data jsonb not null,
  updated_at timestamptz not null default now()
);

create table public.plays (
  user_id uuid not null references public.profiles (id) on delete cascade,
  played_at timestamptz not null,
  track_id text not null references public.tracks (id),
  duration_ms integer not null,
  primary key (user_id, played_at)
);
create index plays_track_id_idx on public.plays (track_id);

alter table public.tracks enable row level security;
alter table public.plays enable row level security;
revoke all on table public.tracks, public.plays from anon, authenticated;

-- p_items: [{ "at": "<played_at>", "track": <slimmed track> }, ...]
create function public.app_store_plays(p_user uuid, p_items jsonb)
returns integer language plpgsql set search_path = '' as $$
declare
  v_count integer;
begin
  insert into public.tracks (id, data, updated_at)
  select distinct on (i->'track'->>'id') i->'track'->>'id', i->'track', now()
  from jsonb_array_elements(p_items) i
  where coalesce(i->'track'->>'id', '') <> ''
  on conflict (id) do update set data = excluded.data, updated_at = now();

  insert into public.plays (user_id, played_at, track_id, duration_ms)
  select p_user, (i->>'at')::timestamptz, i->'track'->>'id', coalesce((i->'track'->>'ms')::integer, 0)
  from jsonb_array_elements(p_items) i
  where coalesce(i->'track'->>'id', '') <> '' and i->>'at' is not null
  on conflict do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create function public.app_collect_targets()
returns uuid[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(user_id), '{}') from public.spotify_tokens where revoked_at is null
$$;

-- Estimated listening time per play. Spotify timestamps a play when it ends, so a play
-- lasted at most the time since the previous play ended, and at most the song's length.
create function public.app_plays_est(p_users uuid[], p_from timestamptz)
returns table (user_id uuid, played_at timestamptz, track_id text, ms bigint)
language sql stable set search_path = '' as $$
  select x.user_id, x.played_at, x.track_id, x.ms
  from (
    select pl.user_id, pl.played_at, pl.track_id,
      least(
        pl.duration_ms::bigint,
        coalesce((extract(epoch from pl.played_at - lag(pl.played_at) over w) * 1000)::bigint, pl.duration_ms::bigint)
      ) as ms
    from public.plays pl
    where pl.user_id = any (p_users)
      and pl.played_at >= p_from - interval '1 day'
    window w as (partition by pl.user_id order by pl.played_at)
  ) x
  where x.played_at >= p_from
$$;

create function public.app_history(p_user uuid, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_tz text := coalesce((select name from pg_catalog.pg_timezone_names where name = p_tz limit 1), 'UTC');
  v_today date := (now() at time zone v_tz)::date;
  v_week timestamptz := ((v_today - 6)::timestamp) at time zone v_tz;
  v_prev timestamptz := ((v_today - 13)::timestamp) at time zone v_tz;
  v_month timestamptz := ((v_today - 27)::timestamp) at time zone v_tz;
  v_out jsonb;
begin
  with e as (
    select x.played_at, x.track_id, x.ms,
           (x.played_at at time zone v_tz)::date as d,
           extract(hour from x.played_at at time zone v_tz)::int as h
    from public.app_plays_est(array[p_user], '-infinity'::timestamptz) x
  ),
  days as (
    select g.d, coalesce(sum(e.ms), 0)::bigint as ms
    from (select (v_today - i) as d from generate_series(0, 13) i) g
    left join e on e.d = g.d
    group by g.d
  ),
  islands as (
    select max(t.d) as last_d, count(*) as len
    from (
      select s.d, s.d - (row_number() over (order by s.d))::int as grp
      from (select distinct e.d from e) s
    ) t
    group by t.grp
  ),
  hours as (
    select hh, count(e.h) as n
    from generate_series(0, 23) hh
    left join e on e.h = hh and e.played_at >= v_month
    group by hh
  ),
  tt as (
    select e.track_id, count(*) as plays, sum(e.ms)::bigint as ms
    from e
    where e.played_at >= v_week
    group by e.track_id
    order by count(*) desc, sum(e.ms) desc
    limit 20
  ),
  ta as (
    select a->>'id' as id, a->>'name' as name, count(*) as plays, sum(e.ms)::bigint as ms
    from e
    join public.tracks t on t.id = e.track_id
    cross join lateral jsonb_array_elements(t.data->'artists') a
    where e.played_at >= v_week
    group by 1, 2
    order by sum(e.ms) desc, count(*) desc
    limit 20
  )
  select jsonb_build_object(
    'tz', v_tz,
    'since', (select min(e.played_at) from e),
    'total_plays', (select count(*) from e),
    'total_ms', (select coalesce(sum(e.ms), 0) from e),
    'today_ms', (select coalesce(sum(e.ms), 0) from e where e.d = v_today),
    'week_ms', (select coalesce(sum(e.ms), 0) from e where e.played_at >= v_week),
    'week_plays', (select count(*) from e where e.played_at >= v_week),
    'prev_week_ms', (select coalesce(sum(e.ms), 0) from e where e.played_at >= v_prev and e.played_at < v_week),
    'streak', coalesce((select i.len from islands i where i.last_d >= v_today - 1 order by i.last_d desc limit 1), 0),
    'days', (select jsonb_agg(jsonb_build_object('d', days.d, 'ms', days.ms) order by days.d) from days),
    'hours', (select jsonb_agg(hours.n order by hours.hh) from hours),
    'hours_plays', (select count(*) from e where e.played_at >= v_month),
    'top_tracks', coalesce((
      select jsonb_agg(jsonb_build_object('track', t.data, 'plays', tt.plays, 'ms', tt.ms) order by tt.plays desc, tt.ms desc)
      from tt join public.tracks t on t.id = tt.track_id
    ), '[]'::jsonb),
    'top_artists', coalesce((
      select jsonb_agg(jsonb_build_object('id', ta.id, 'name', ta.name, 'plays', ta.plays, 'ms', ta.ms) order by ta.ms desc, ta.plays desc)
      from ta
    ), '[]'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

-- Listening time over the last 7 days for you and your friends.
create function public.app_leaderboard(p_viewer uuid, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_tz text := coalesce((select name from pg_catalog.pg_timezone_names where name = p_tz limit 1), 'UTC');
  v_week timestamptz := ((((now() at time zone v_tz)::date) - 6)::timestamp) at time zone v_tz;
  v_people uuid[];
begin
  select array_agg(s.id) into v_people
  from (
    select p_viewer as id
    union
    select f.friend_id from public.friendships f where f.user_id = p_viewer
  ) s;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', p.id, 'ms', coalesce(x.ms, 0), 'plays', coalesce(x.plays, 0))
                     order by coalesce(x.ms, 0) desc, p.id)
    from unnest(v_people) as p(id)
    left join (
      select e.user_id, sum(e.ms)::bigint as ms, count(*) as plays
      from public.app_plays_est(v_people, v_week) e
      group by e.user_id
    ) x on x.user_id = p.id
  ), '[]'::jsonb);
end;
$$;

do $$
declare
  f regprocedure;
begin
  for f in
    select p.oid::regprocedure
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname like 'app\_%'
  loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end;
$$;

-- Every 20 minutes, ask the backend to save everyone's recent plays.
insert into public.app_settings (key, value)
values ('cron_secret', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''));

select cron.schedule(
  'rotation-collect-plays',
  '*/20 * * * *',
  $cron$
  select net.http_post(
    url := 'https://ohcfeqlcecvfxhnpmujr.supabase.co/functions/v1/api/cron/collect',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select value from public.app_settings where key = 'cron_secret')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 60000
  );
  $cron$
);

notify pgrst, 'reload schema';
