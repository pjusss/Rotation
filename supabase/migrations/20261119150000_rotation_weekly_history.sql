-- Weekly history: listening time for every Monday-to-Sunday week since Rotation started
-- logging someone's plays, newest first, with each week's daily split and top songs and
-- artists. Weeks with no plays are included, so the line graph has no gaps.

create function public.app_weeks(p_user uuid, p_tz text)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_tz text := coalesce((select name from pg_catalog.pg_timezone_names where name = p_tz limit 1), 'UTC');
  v_today date := (now() at time zone v_tz)::date;
  v_this date := v_today - (extract(isodow from v_today)::int - 1);
  v_since timestamptz;
  v_first_day date;
  v_first date;
  v_out jsonb;
begin
  select min(pl.played_at) into v_since from public.plays pl where pl.user_id = p_user;
  if v_since is null then
    return jsonb_build_object('tz', v_tz, 'today', v_today, 'since', null, 'first_day', null,
                              'weeks', '[]'::jsonb, 'tracks', '{}'::jsonb);
  end if;
  v_first_day := (v_since at time zone v_tz)::date;
  -- Monday of the first week, keeping at most 156 weeks (3 years).
  v_first := greatest(v_first_day - (extract(isodow from v_first_day)::int - 1), v_this - 7 * 155);

  with e as (
    select x.track_id, x.ms, (x.played_at at time zone v_tz)::date as d
    from public.app_plays_est(array[p_user], (v_first::timestamp at time zone v_tz)) x
  ),
  ew as (
    select e.track_id, e.ms, e.d, e.d - (extract(isodow from e.d)::int - 1) as w
    from e
  ),
  wk as (
    select v_first + 7 * i as w from generate_series(0, (v_this - v_first) / 7) i
  ),
  tot as (
    select ew.w, sum(ew.ms)::bigint as ms, count(*)::int as plays, count(distinct ew.d)::int as active
    from ew
    group by ew.w
  ),
  dd as (
    select ew.w, ew.d - ew.w as i, sum(ew.ms)::bigint as ms
    from ew
    group by ew.w, ew.d
  ),
  tt as (
    select s.w, s.track_id, s.plays, s.ms
    from (
      select ew.w, ew.track_id, count(*)::int as plays, sum(ew.ms)::bigint as ms,
             row_number() over (partition by ew.w order by count(*) desc, sum(ew.ms) desc, ew.track_id) as rn
      from ew
      group by ew.w, ew.track_id
    ) s
    where s.rn <= 5
  ),
  ta as (
    select s.w, s.id, s.name, s.plays, s.ms
    from (
      select ew.w, a->>'id' as id, max(a->>'name') as name, count(*)::int as plays, sum(ew.ms)::bigint as ms,
             row_number() over (partition by ew.w order by sum(ew.ms) desc, count(*) desc, a->>'id') as rn
      from ew
      join public.tracks t on t.id = ew.track_id
      cross join lateral jsonb_array_elements(t.data->'artists') a
      where coalesce(a->>'id', '') <> ''
      group by ew.w, a->>'id'
    ) s
    where s.rn <= 5
  )
  select jsonb_build_object(
    'tz', v_tz,
    'today', v_today,
    'since', v_since,
    'first_day', v_first_day,
    'weeks', (
      select jsonb_agg(jsonb_build_object(
        'w', wk.w,
        'ms', coalesce(tot.ms, 0),
        'plays', coalesce(tot.plays, 0),
        'active', coalesce(tot.active, 0),
        'days', (
          select jsonb_agg(coalesce(dd.ms, 0) order by g.i)
          from generate_series(0, 6) g(i)
          left join dd on dd.w = wk.w and dd.i = g.i
        ),
        'tracks', coalesce((
          select jsonb_agg(jsonb_build_object('id', tt.track_id, 'plays', tt.plays, 'ms', tt.ms)
                           order by tt.plays desc, tt.ms desc, tt.track_id)
          from tt where tt.w = wk.w
        ), '[]'::jsonb),
        'artists', coalesce((
          select jsonb_agg(jsonb_build_object('id', ta.id, 'name', ta.name, 'plays', ta.plays, 'ms', ta.ms)
                           order by ta.ms desc, ta.plays desc, ta.id)
          from ta where ta.w = wk.w
        ), '[]'::jsonb)
      ) order by wk.w desc)
      from wk
      left join tot on tot.w = wk.w
    ),
    -- Song details once each, shared by every week that lists them.
    'tracks', coalesce((
      select jsonb_object_agg(t.id, t.data)
      from public.tracks t
      where t.id in (select tt.track_id from tt)
    ), '{}'::jsonb)
  ) into v_out;
  return v_out;
end;
$$;

revoke all on function public.app_weeks(uuid, text) from public, anon, authenticated;
grant execute on function public.app_weeks(uuid, text) to service_role;

notify pgrst, 'reload schema';
