-- Spotify redirects to the backend, which hands the browser a one-time ticket.
-- The ticket only works together with the random nonce the browser kept when it started the login.

create table public.auth_requests (
  state text primary key,
  verifier text not null,
  return_to text not null,
  nonce_hash text not null,
  created_at timestamptz not null default now()
);

create table public.login_tickets (
  ticket_hash text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  nonce_hash text not null,
  created_at timestamptz not null default now()
);
create index login_tickets_user_id_idx on public.login_tickets (user_id);

alter table public.auth_requests enable row level security;
alter table public.login_tickets enable row level security;
revoke all on table public.auth_requests, public.login_tickets from anon, authenticated;

-- Replaces app_login, which created sessions directly; sessions now come from app_ticket_redeem.
create function public.app_upsert_user(
  p_spotify_id text, p_name text, p_avatar text, p_url text,
  p_refresh text, p_access text, p_expires timestamptz, p_scope text
) returns uuid language plpgsql set search_path = '' as $$
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

  return v_id;
end;
$$;

create function public.app_auth_start(p_state text, p_verifier text, p_return_to text, p_nonce_hash text)
returns void language plpgsql set search_path = '' as $$
begin
  delete from public.auth_requests where created_at < now() - interval '15 minutes';
  insert into public.auth_requests (state, verifier, return_to, nonce_hash)
  values (p_state, p_verifier, p_return_to, p_nonce_hash);
end;
$$;

create function public.app_auth_take(p_state text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_row public.auth_requests;
begin
  delete from public.auth_requests
  where state = p_state and created_at > now() - interval '15 minutes'
  returning * into v_row;
  if v_row.state is null then
    return null;
  end if;
  return jsonb_build_object('verifier', v_row.verifier, 'return_to', v_row.return_to, 'nonce_hash', v_row.nonce_hash);
end;
$$;

create function public.app_ticket_create(p_ticket_hash text, p_user uuid, p_nonce_hash text)
returns void language plpgsql set search_path = '' as $$
begin
  delete from public.login_tickets where created_at < now() - interval '10 minutes';
  insert into public.login_tickets (ticket_hash, user_id, nonce_hash)
  values (p_ticket_hash, p_user, p_nonce_hash);
end;
$$;

create function public.app_ticket_redeem(p_ticket_hash text, p_nonce_hash text, p_session_hash text)
returns jsonb language plpgsql set search_path = '' as $$
declare
  v_user uuid;
begin
  delete from public.login_tickets
  where ticket_hash = p_ticket_hash
    and nonce_hash = p_nonce_hash
    and created_at > now() - interval '3 minutes'
  returning user_id into v_user;
  if v_user is null then
    return null;
  end if;
  insert into public.sessions (token_hash, user_id) values (p_session_hash, v_user);
  return public.app_me(v_user);
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

insert into public.app_settings (key, value)
values ('spotify_redirect_uri', 'https://ohcfeqlcecvfxhnpmujr.supabase.co/functions/v1/api/callback');

notify pgrst, 'reload schema';
