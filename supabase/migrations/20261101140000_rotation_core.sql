-- Rotation: Spotify accounts, sessions, friends and cached stats.
-- Only the api edge function (secret key) reads or writes these tables.

create table public.profiles (
  id uuid primary key default gen_random_uuid(),
  spotify_id text not null unique,
  display_name text not null,
  avatar_url text,
  spotify_url text,
  invite_code text not null unique default substr(replace(gen_random_uuid()::text, '-', ''), 1, 12),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.spotify_tokens (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  refresh_token text not null,
  access_token text,
  expires_at timestamptz,
  scope text,
  revoked_at timestamptz,
  updated_at timestamptz not null default now()
);

create table public.sessions (
  token_hash text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  last_used_at timestamptz not null default now()
);
create index sessions_user_id_idx on public.sessions (user_id);

create table public.friendships (
  user_id uuid not null references public.profiles (id) on delete cascade,
  friend_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  constraint friendships_not_self check (user_id <> friend_id)
);
create index friendships_friend_id_idx on public.friendships (friend_id);

create table public.stats_cache (
  user_id uuid not null references public.profiles (id) on delete cascade,
  kind text not null,
  data jsonb not null,
  fetched_at timestamptz not null default now(),
  primary key (user_id, kind)
);

create table public.app_settings (
  key text primary key,
  value text not null
);

alter table public.profiles enable row level security;
alter table public.spotify_tokens enable row level security;
alter table public.sessions enable row level security;
alter table public.friendships enable row level security;
alter table public.stats_cache enable row level security;
alter table public.app_settings enable row level security;

revoke all on table public.profiles, public.spotify_tokens, public.sessions,
  public.friendships, public.stats_cache, public.app_settings from anon, authenticated;

-- Functions the edge function calls through /rest/v1/rpc.

create function public.app_profile_json(p public.profiles)
returns jsonb language sql immutable set search_path = '' as $$
  select jsonb_build_object('id', p.id, 'name', p.display_name, 'avatar', p.avatar_url, 'url', p.spotify_url)
$$;

create function public.app_me(p_user uuid)
returns jsonb language sql stable set search_path = '' as $$
  select public.app_profile_json(p) || jsonb_build_object(
    'invite_code', p.invite_code,
    'friends', coalesce((
      select jsonb_agg(public.app_profile_json(f) || jsonb_build_object('since', fr.created_at) order by fr.created_at)
      from public.friendships fr
      join public.profiles f on f.id = fr.friend_id
      where fr.user_id = p.id
    ), '[]'::jsonb)
  )
  from public.profiles p
  where p.id = p_user
$$;

-- Superseded by app_upsert_user in the next migration; no longer called.
create function public.app_login(
  p_spotify_id text, p_name text, p_avatar text, p_url text,
  p_refresh text, p_access text, p_expires timestamptz, p_scope text, p_session_hash text
) returns jsonb language plpgsql set search_path = '' as $$
declare
  v_id uuid;
begin
  insert into public.profiles (spotify_id, display_name, avatar_url, spotify_url)
  values (p_spotify_id, p_name, p_avatar, p_url)
  on conflict (spotify_id) do update
    set display_name = excluded.display_name,
        avatar_url = excluded.avatar_url,
        spotify_url = excluded.spotify_url,
        updated_at = now()
  returning id into v_id;

  insert into public.spotify_tokens (user_id, refresh_token, access_token, expires_at, scope)
  values (v_id, p_refresh, p_access, p_expires, p_scope)
  on conflict (user_id) do update
    set refresh_token = excluded.refresh_token,
        access_token = excluded.access_token,
        expires_at = excluded.expires_at,
        scope = excluded.scope,
        revoked_at = null,
        updated_at = now();

  insert into public.sessions (token_hash, user_id) values (p_session_hash, v_id);
  return public.app_me(v_id);
end;
$$;

create function public.app_session_user(p_hash text)
returns uuid language plpgsql set search_path = '' as $$
declare
  v_user uuid;
  v_last timestamptz;
begin
  select user_id, last_used_at into v_user, v_last from public.sessions where token_hash = p_hash;
  if v_user is null then
    return null;
  end if;
  if v_last < now() - interval '180 days' then
    delete from public.sessions where token_hash = p_hash;
    return null;
  end if;
  if v_last < now() - interval '1 hour' then
    update public.sessions set last_used_at = now() where token_hash = p_hash;
  end if;
  return v_user;
end;
$$;

create function public.app_logout(p_hash text)
returns void language sql set search_path = '' as $$
  delete from public.sessions where token_hash = p_hash;
$$;

create function public.app_view(p_viewer uuid, p_target uuid)
returns jsonb language sql stable set search_path = '' as $$
  select public.app_profile_json(p)
  from public.profiles p
  where p.id = p_target
    and (p_target = p_viewer or exists (
      select 1 from public.friendships f where f.user_id = p_viewer and f.friend_id = p_target))
$$;

create function public.app_viewable(p_viewer uuid, p_targets uuid[])
returns uuid[] language sql stable set search_path = '' as $$
  select coalesce(array_agg(distinct t), '{}')
  from unnest(p_targets) as t
  where t = p_viewer or exists (
    select 1 from public.friendships f where f.user_id = p_viewer and f.friend_id = t)
$$;

create function public.app_invite_preview(p_code text)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('name', p.display_name, 'avatar', p.avatar_url)
  from public.profiles p
  where p.invite_code = p_code
$$;

create function public.app_accept_invite(p_user uuid, p_code text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_friend public.profiles;
begin
  select * into v_friend from public.profiles where invite_code = p_code;
  if not found then
    return jsonb_build_object('error', 'invalid_invite');
  end if;
  if v_friend.id = p_user then
    return jsonb_build_object('error', 'own_invite');
  end if;
  insert into public.friendships (user_id, friend_id)
  values (p_user, v_friend.id), (v_friend.id, p_user)
  on conflict do nothing;
  return jsonb_build_object('friend', public.app_profile_json(v_friend));
end;
$$;

create function public.app_remove_friend(p_user uuid, p_friend uuid)
returns void language sql set search_path = '' as $$
  delete from public.friendships
  where (user_id = p_user and friend_id = p_friend)
     or (user_id = p_friend and friend_id = p_user);
$$;

create function public.app_delete_account(p_user uuid)
returns void language sql set search_path = '' as $$
  delete from public.profiles where id = p_user;
$$;

create function public.app_token_get(p_user uuid)
returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object(
    'refresh_token', refresh_token,
    'access_token', access_token,
    'expires_at', expires_at,
    'revoked', revoked_at is not null)
  from public.spotify_tokens
  where user_id = p_user
$$;

create function public.app_token_save(p_user uuid, p_access text, p_expires timestamptz, p_refresh text)
returns void language sql set search_path = '' as $$
  update public.spotify_tokens
  set access_token = p_access,
      expires_at = p_expires,
      refresh_token = coalesce(p_refresh, refresh_token),
      revoked_at = null,
      updated_at = now()
  where user_id = p_user;
$$;

create function public.app_token_revoke(p_user uuid)
returns void language sql set search_path = '' as $$
  update public.spotify_tokens
  set revoked_at = now(), access_token = null, updated_at = now()
  where user_id = p_user;
$$;

create function public.app_cache_get(p_users uuid[], p_kind text, p_max_age_s integer)
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_object_agg(user_id::text, jsonb_build_object('data', data, 'fetched_at', fetched_at)), '{}'::jsonb)
  from public.stats_cache
  where user_id = any (p_users)
    and kind = p_kind
    and fetched_at > now() - make_interval(secs => p_max_age_s)
$$;

create function public.app_cache_put(p_user uuid, p_kind text, p_data jsonb)
returns timestamptz language sql set search_path = '' as $$
  insert into public.stats_cache (user_id, kind, data, fetched_at)
  values (p_user, p_kind, p_data, now())
  on conflict (user_id, kind) do update
    set data = excluded.data, fetched_at = excluded.fetched_at
  returning fetched_at;
$$;

create function public.app_get_settings()
returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_object_agg(key, value), '{}'::jsonb) from public.app_settings
$$;

-- Nobody but the backend (service role) may call these.
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

notify pgrst, 'reload schema';
