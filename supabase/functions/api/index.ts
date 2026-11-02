// Rotation API: Spotify login, sessions, stats, now playing and friends.
//
// Deployed with verify_jwt off. Browsers authenticate with the app's own session
// token (x-session header). The database is only reached through the app_* SQL
// functions, called with the project's secret key.
//
// Login flow: POST /auth/start -> Spotify -> GET /callback (this function) ->
// redirect back to the app with a one-time ticket -> POST /auth/redeem.
// The ticket only works together with the random nonce the browser sent to
// /auth/start, so a login can't be completed in someone else's browser.

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SECRET_KEY = readSecretKey();
const SCOPES = 'user-top-read user-read-recently-played user-read-currently-playing';
const ACCOUNTS = 'https://accounts.spotify.com';
const SPOTIFY = 'https://api.spotify.com/v1';
const RANGES = ['short_term', 'medium_term', 'long_term'];
// How long a cached copy stays good, in seconds. A "fresh" request accepts only a younger copy.
const TTL: Record<string, number> = { top: 3600, recent: 300, now: 40 };
const FRESH_TTL: Record<string, number> = { top: 120, recent: 30, now: 15 };
const STALE_OK = 60 * 60 * 24 * 365;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
  'Access-Control-Allow-Headers': 'content-type, x-session',
  'Access-Control-Max-Age': '86400',
};

function readSecretKey(): string {
  try {
    const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    const key = keys.default ?? Object.values(keys)[0];
    if (key) return String(key);
  } catch {
    // fall back to the legacy key below
  }
  return Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
}

class HttpError extends Error {
  status: number;
  code: string;
  constructor(status: number, code: string, message?: string) {
    super(message || code);
    this.status = status;
    this.code = code;
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

function plain(status: number, body: string): Response {
  return new Response(body, { status, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' } });
}

function redirect(location: string): Response {
  return new Response(null, {
    status: 302,
    headers: { Location: location, 'Cache-Control': 'no-store', 'Referrer-Policy': 'no-referrer' },
  });
}

const readBody = (req: Request): Promise<any> => req.json().catch(() => null);
const str = (v: unknown) => (typeof v === 'string' ? v : '');
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/* ---------- Database ---------- */

async function rpc(fn: string, args: Record<string, unknown> = {}): Promise<any> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', apikey: SECRET_KEY };
  // Legacy service_role keys are JWTs and also go in Authorization; new sb_secret_ keys must not.
  if (SECRET_KEY.startsWith('eyJ')) headers.Authorization = `Bearer ${SECRET_KEY}`;
  const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, { method: 'POST', headers, body: JSON.stringify(args) });
  const body = await res.text();
  if (!res.ok) {
    console.error(`rpc ${fn} failed`, res.status, body.slice(0, 300));
    throw new HttpError(500, 'db_error', 'The database request failed.');
  }
  return body ? JSON.parse(body) : null;
}

let settingsCache: { at: number; value: Record<string, string> } = { at: 0, value: {} };
async function settings(): Promise<Record<string, string>> {
  if (Date.now() - settingsCache.at < 30_000) return settingsCache.value;
  const value = (await rpc('app_get_settings')) ?? {};
  settingsCache = { at: Date.now(), value };
  return value;
}
const clientId = async () => ((await settings()).spotify_client_id ?? '').trim();
const callbackUrl = async () => (await settings()).spotify_redirect_uri || `${SUPABASE_URL}/functions/v1/api/callback`;
const allowedOrigins = async () =>
  ((await settings()).app_origins ?? '').split(',').map((s) => s.trim()).filter(Boolean);

/* ---------- Crypto ---------- */

const encoder = new TextEncoder();
function base64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
const randomToken = (bytes = 32) => base64url(crypto.getRandomValues(new Uint8Array(bytes)));
async function sha256Bytes(s: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest('SHA-256', encoder.encode(s)));
}
async function sha256(s: string): Promise<string> {
  return Array.from(await sha256Bytes(s), (b) => b.toString(16).padStart(2, '0')).join('');
}

/* ---------- Spotify data, slimmed to what the app shows ---------- */

function pickImg(images: any[] | undefined, min: number): string | null {
  if (!images || !images.length) return null;
  const sorted = [...images].sort((a, b) => (a.width || 0) - (b.width || 0));
  return (sorted.find((i) => (i.width || 0) >= min) || sorted[sorted.length - 1]).url ?? null;
}
const sizes = (images: any[] | undefined) => ({ sm: pickImg(images, 100), md: pickImg(images, 280), lg: pickImg(images, 600) });

function slimArtist(a: any) {
  return { id: a.id, name: a.name, url: a.external_urls?.spotify ?? null, genres: a.genres ?? [], ...sizes(a.images) };
}

function slimTrack(t: any) {
  const al = t.album ?? {};
  return {
    id: t.id || t.uri || t.name,
    name: t.name,
    url: t.external_urls?.spotify ?? null,
    ms: t.duration_ms ?? null,
    explicit: !!t.explicit,
    artists: (t.artists ?? []).map((a: any) => ({ id: a.id || a.name, name: a.name })),
    album: {
      id: al.id || al.name || '',
      name: al.name ?? '',
      url: al.external_urls?.spotify ?? null,
      type: al.album_type ?? null,
      date: al.release_date ?? null,
      artists: (al.artists ?? []).map((a: any) => a.name),
      ...sizes(al.images),
    },
  };
}

/* ---------- Spotify tokens and calls ---------- */

const tokenCache = new Map<string, { token: string; exp: number }>();
const inflight = new Map<string, Promise<string>>();
const disconnected = () => new HttpError(409, 'disconnected', 'Spotify is no longer connected for this account.');

function accessToken(userId: string, force = false): Promise<string> {
  if (!force) {
    const c = tokenCache.get(userId);
    if (c && c.exp - Date.now() > 60_000) return Promise.resolve(c.token);
  }
  const key = `${userId}:${force}`;
  let p = inflight.get(key);
  if (!p) {
    p = loadAccessToken(userId, force).finally(() => inflight.delete(key));
    inflight.set(key, p);
  }
  return p;
}

async function loadAccessToken(userId: string, force: boolean): Promise<string> {
  const t = await rpc('app_token_get', { p_user: userId });
  if (!t || t.revoked || !t.refresh_token) throw disconnected();
  if (!force && t.access_token && Date.parse(t.expires_at) - Date.now() > 60_000) {
    tokenCache.set(userId, { token: t.access_token, exp: Date.parse(t.expires_at) });
    return t.access_token;
  }
  const res = await fetch(`${ACCOUNTS}/api/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: t.refresh_token, client_id: await clientId() }),
  });
  const j = await res.json().catch(() => ({}));
  if (!res.ok) {
    if (j.error === 'invalid_grant') {
      // Another request may have just rotated the refresh token. Use its result if so.
      const again = await rpc('app_token_get', { p_user: userId });
      if (again && !again.revoked && again.refresh_token !== t.refresh_token && again.access_token &&
          Date.parse(again.expires_at) - Date.now() > 60_000) {
        tokenCache.set(userId, { token: again.access_token, exp: Date.parse(again.expires_at) });
        return again.access_token;
      }
      await rpc('app_token_revoke', { p_user: userId });
      tokenCache.delete(userId);
      throw disconnected();
    }
    throw new HttpError(502, 'spotify_error', j.error_description || j.error || `Spotify token request failed (${res.status}).`);
  }
  const exp = Date.now() + (Number(j.expires_in) || 3600) * 1000;
  await rpc('app_token_save', {
    p_user: userId,
    p_access: j.access_token,
    p_expires: new Date(exp).toISOString(),
    p_refresh: j.refresh_token ?? null,
  });
  tokenCache.set(userId, { token: j.access_token, exp });
  return j.access_token;
}

const forbiddenCode = (message: string) => (/regist/i.test(message) ? 'not_allowlisted' : 'spotify_forbidden');

async function spotify(userId: string, path: string): Promise<any> {
  let token = await accessToken(userId);
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(SPOTIFY + path, { headers: { Authorization: `Bearer ${token}` } });
    if (res.status === 204) return null;
    const body = await res.json().catch(() => null);
    if (res.ok) return body;
    const message = body?.error?.message ?? '';
    if (res.status === 401 && attempt === 0) {
      tokenCache.delete(userId);
      token = await accessToken(userId, true);
      continue;
    }
    if (res.status === 429) {
      const reason = body?.error?.reason ?? body?.reason ?? '';
      if (reason !== 'QUOTA_EXCEEDED' && attempt < 2) {
        await sleep(Math.min(Math.max(Number(res.headers.get('retry-after')) || 1, 1), 4) * 1000);
        continue;
      }
      throw new HttpError(429, reason === 'QUOTA_EXCEEDED' ? 'quota' : 'rate_limited', 'Spotify is limiting requests right now.');
    }
    if (res.status === 403) throw new HttpError(403, forbiddenCode(message), message);
    if (res.status === 401) throw disconnected();
    throw new HttpError(502, 'spotify_error', message || `Spotify returned ${res.status}.`);
  }
}

async function fetchTop(userId: string) {
  const res = await Promise.all(RANGES.flatMap((r) => [
    spotify(userId, `/me/top/artists?time_range=${r}&limit=50`),
    spotify(userId, `/me/top/tracks?time_range=${r}&limit=50`),
  ]));
  const top: Record<string, unknown> = {};
  RANGES.forEach((r, i) => {
    top[r] = {
      artists: (res[2 * i]?.items ?? []).filter((a: any) => a && a.id).map(slimArtist),
      tracks: (res[2 * i + 1]?.items ?? []).filter((t: any) => t && t.name).map(slimTrack),
    };
  });
  return top;
}

async function fetchRecentRaw(userId: string): Promise<any[]> {
  const r = await spotify(userId, '/me/player/recently-played?limit=50');
  return (r?.items ?? []).filter((i: any) => i && i.track && i.track.name && i.played_at);
}

// Saves plays into the history tables. Local files have no Spotify ID and are skipped.
async function savePlays(userId: string, raw: any[]): Promise<number> {
  const items = raw.filter((i) => i.track.id).map((i) => ({ at: i.played_at, track: slimTrack(i.track) }));
  if (!items.length) return 0;
  return (await rpc('app_store_plays', { p_user: userId, p_items: items })) ?? 0;
}

const recentFrom = (raw: any[]) => raw.map((i: any) => ({ at: i.played_at, ...slimTrack(i.track) }));

async function fetchRecent(userId: string) {
  const raw = await fetchRecentRaw(userId);
  await savePlays(userId, raw).catch((e) => console.error('saving plays failed', e));
  return recentFrom(raw);
}

// Run by the scheduled job: save someone's latest plays and refresh their recent list.
async function collect(userId: string): Promise<number> {
  const raw = await fetchRecentRaw(userId);
  const stored = await savePlays(userId, raw);
  await rpc('app_cache_put', { p_user: userId, p_kind: 'recent', p_data: recentFrom(raw) });
  return stored;
}

async function fetchNow(userId: string) {
  const r = await spotify(userId, '/me/player/currently-playing');
  if (!r || !r.item || r.currently_playing_type !== 'track') return null;
  return { playing: !!r.is_playing, ...slimTrack(r.item) };
}

// Returns a cached copy when it's young enough; otherwise asks Spotify. If Spotify fails
// and an older copy exists, that copy comes back marked stale instead of an error.
async function cached(userId: string, kind: string, fresh: boolean, load: (id: string) => Promise<unknown>) {
  const maxAge = fresh ? FRESH_TTL[kind] : TTL[kind];
  const hit = (await rpc('app_cache_get', { p_users: [userId], p_kind: kind, p_max_age_s: maxAge }))?.[userId];
  if (hit) return hit;
  try {
    const data = await load(userId);
    const fetched_at = await rpc('app_cache_put', { p_user: userId, p_kind: kind, p_data: data });
    return { data, fetched_at };
  } catch (e) {
    if (!(e instanceof HttpError) || e.code === 'db_error') throw e;
    const old = (await rpc('app_cache_get', { p_users: [userId], p_kind: kind, p_max_age_s: STALE_OK }))?.[userId];
    if (old) return { ...old, stale: true, error: e.code };
    throw e;
  }
}

/* ---------- Login ---------- */

async function authStart(body: any) {
  const returnTo = str(body?.return_to);
  const nonce = str(body?.nonce);
  if (!returnTo || nonce.length < 16) throw new HttpError(400, 'bad_request', 'Missing login details.');
  let origin = '';
  try {
    origin = new URL(returnTo).origin;
  } catch {
    throw new HttpError(400, 'bad_request', 'Invalid return address.');
  }
  if (returnTo.includes('#') || !(await allowedOrigins()).includes(origin)) {
    throw new HttpError(403, 'origin_not_allowed', 'This site is not allowed to log in to Rotation.');
  }
  const cid = await clientId();
  if (!cid) throw new HttpError(503, 'not_configured', "Spotify isn't connected to this app yet.");
  const state = randomToken(24);
  const verifier = randomToken(48);
  await rpc('app_auth_start', { p_state: state, p_verifier: verifier, p_return_to: returnTo, p_nonce_hash: await sha256(nonce) });
  const q = new URLSearchParams({
    response_type: 'code',
    client_id: cid,
    scope: SCOPES,
    redirect_uri: await callbackUrl(),
    state,
    code_challenge_method: 'S256',
    code_challenge: base64url(await sha256Bytes(verifier)),
  });
  return { url: `${ACCOUNTS}/authorize?${q}` };
}

async function callback(url: URL): Promise<Response> {
  const state = url.searchParams.get('state') ?? '';
  const pending = state ? await rpc('app_auth_take', { p_state: state }) : null;
  if (!pending) return plain(400, 'This login link has expired. Go back to Rotation and try again.');
  const back = (fragment: string) => redirect(`${pending.return_to}#${fragment}`);
  const error = url.searchParams.get('error');
  if (error) return back(`login_error=${error === 'access_denied' ? 'cancelled' : 'spotify_error'}`);
  try {
    const tokRes = await fetch(`${ACCOUNTS}/api/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'authorization_code',
        code: url.searchParams.get('code') ?? '',
        redirect_uri: await callbackUrl(),
        client_id: await clientId(),
        code_verifier: pending.verifier,
      }),
    });
    const tok = await tokRes.json().catch(() => ({}));
    if (!tokRes.ok || !tok.access_token || !tok.refresh_token) {
      console.error('token exchange failed', tokRes.status, tok.error, tok.error_description);
      return back(`login_error=${tok.error === 'invalid_grant' ? 'login_expired' : 'spotify_error'}`);
    }
    const meRes = await fetch(`${SPOTIFY}/me`, { headers: { Authorization: `Bearer ${tok.access_token}` } });
    const me = await meRes.json().catch(() => ({}));
    if (!meRes.ok || !me.id) {
      const message = me?.error?.message ?? '';
      console.error('profile request failed', meRes.status, message);
      return back(`login_error=${meRes.status === 403 ? forbiddenCode(message) : 'spotify_error'}`);
    }
    const userId: string = await rpc('app_upsert_user', {
      p_spotify_id: me.id,
      p_name: me.display_name || me.id,
      p_avatar: pickImg(me.images, 160),
      p_url: me.external_urls?.spotify ?? null,
      p_refresh: tok.refresh_token,
      p_access: tok.access_token,
      p_expires: new Date(Date.now() + (Number(tok.expires_in) || 3600) * 1000).toISOString(),
      p_scope: tok.scope ?? SCOPES,
    });
    tokenCache.delete(userId);
    const ticket = randomToken(32);
    await rpc('app_ticket_create', { p_ticket_hash: await sha256(ticket), p_user: userId, p_nonce_hash: pending.nonce_hash });
    return back(`ticket=${ticket}`);
  } catch (e) {
    console.error('callback failed', e);
    return back(`login_error=${e instanceof HttpError ? e.code : 'server_error'}`);
  }
}

async function redeem(body: any) {
  const ticket = str(body?.ticket);
  const nonce = str(body?.nonce);
  if (!ticket || !nonce) throw new HttpError(400, 'bad_request', 'Missing login details.');
  const session = randomToken(32);
  const me = await rpc('app_ticket_redeem', {
    p_ticket_hash: await sha256(ticket),
    p_nonce_hash: await sha256(nonce),
    p_session_hash: await sha256(session),
  });
  if (!me) throw new HttpError(400, 'login_expired', 'That login expired. Try again.');
  return { session, me };
}

/* ---------- Stats and friends ---------- */

async function stats(viewer: string, target: string, fresh: boolean, tz: string) {
  if (!UUID.test(target)) throw new HttpError(400, 'bad_request', 'Unknown user.');
  const user = await rpc('app_view', { p_viewer: viewer, p_target: target });
  if (!user) throw new HttpError(403, 'not_friends', 'You can only see stats of your friends.');
  const [top, recent] = await Promise.all([
    cached(target, 'top', fresh, fetchTop),
    cached(target, 'recent', fresh, fetchRecent).catch((e) => {
      if (e instanceof HttpError && e.code !== 'db_error') return { data: [], fetched_at: null };
      throw e;
    }),
  ]);
  // Computed after the recent plays above were saved, so it includes them.
  const history = await rpc('app_history', { p_user: target, p_tz: tz }).catch((e) => {
    console.error('history failed', e);
    return null;
  });
  return {
    user, top: top.data, recent: recent.data ?? [], history,
    fetched_at: top.fetched_at, stale: !!top.stale, error: top.error ?? null,
  };
}

async function nowPlaying(viewer: string, ids: string[]) {
  const wanted = [...new Set(ids.map((id) => (id === 'me' ? viewer : id)).filter((id) => UUID.test(id)))].slice(0, 12);
  if (!wanted.length) return {};
  const allowed: string[] = (await rpc('app_viewable', { p_viewer: viewer, p_targets: wanted })) ?? [];
  const hits = (await rpc('app_cache_get', { p_users: allowed, p_kind: 'now', p_max_age_s: TTL.now })) ?? {};
  const out: Record<string, unknown> = {};
  await Promise.all(allowed.map(async (id) => {
    if (hits[id]) {
      out[id] = hits[id].data?.now ?? null;
      return;
    }
    try {
      const now = await fetchNow(id);
      await rpc('app_cache_put', { p_user: id, p_kind: 'now', p_data: { now } });
      out[id] = now;
    } catch (e) {
      if (!(e instanceof HttpError)) console.error('now playing failed', e);
      out[id] = null;
    }
  }));
  return out;
}

/* ---------- Router ---------- */

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: CORS });
  const url = new URL(req.url);
  const path = url.pathname.replace(/^.*?\/api(?=\/|$)/, '') || '/';
  try {
    if (req.method === 'GET' && path === '/callback') return await callback(url);
    if (req.method === 'GET' && path === '/config') {
      const origin = req.headers.get('origin');
      return json(200, { ready: !!(await clientId()), origin_ok: origin ? (await allowedOrigins()).includes(origin) : null });
    }
    if (req.method === 'GET' && path.startsWith('/invite/')) {
      const preview = await rpc('app_invite_preview', { p_code: decodeURIComponent(path.slice('/invite/'.length)) });
      if (!preview) throw new HttpError(404, 'invalid_invite', 'That invite link is not valid.');
      return json(200, preview);
    }
    if (req.method === 'POST' && path === '/auth/start') return json(200, await authStart(await readBody(req)));
    if (req.method === 'POST' && path === '/auth/redeem') return json(200, await redeem(await readBody(req)));
    if (req.method === 'POST' && path === '/cron/collect') {
      const secret = (await settings()).cron_secret ?? '';
      if (!secret || (req.headers.get('x-cron-secret') ?? '') !== secret) throw new HttpError(401, 'unauthorized', 'Not allowed.');
      const ids: string[] = (await rpc('app_collect_targets')) ?? [];
      let stored = 0;
      let failed = 0;
      for (const id of ids) {
        try {
          stored += await collect(id);
        } catch (e) {
          failed++;
          console.error('collect failed', id, e instanceof HttpError ? e.code : e);
        }
      }
      return json(200, { users: ids.length, stored, failed });
    }

    // Everything below needs a session.
    const session = req.headers.get('x-session') ?? '';
    const hash = session ? await sha256(session) : '';
    const viewer: string | null = hash ? await rpc('app_session_user', { p_hash: hash }) : null;
    if (!viewer) throw new HttpError(401, 'signed_out', 'Log in again.');

    const route = `${req.method} ${path}`;
    const tz = (url.searchParams.get('tz') || 'UTC').slice(0, 64);
    if (route === 'GET /me') return json(200, await rpc('app_me', { p_user: viewer }));
    if (route === 'GET /stats') {
      const u = url.searchParams.get('user');
      return json(200, await stats(viewer, !u || u === 'me' ? viewer : u, url.searchParams.get('fresh') === '1', tz));
    }
    if (route === 'GET /leaderboard') return json(200, await rpc('app_leaderboard', { p_viewer: viewer, p_tz: tz }));
    if (route === 'GET /now') return json(200, await nowPlaying(viewer, (url.searchParams.get('users') ?? 'me').split(',')));
    if (route === 'POST /friends') {
      const r = await rpc('app_accept_invite', { p_user: viewer, p_code: str((await readBody(req))?.code) });
      if (r?.error) throw new HttpError(400, r.error, r.error === 'own_invite' ? "That's your own invite link." : 'That invite link is not valid.');
      return json(200, r);
    }
    if (route === 'DELETE /friends') {
      const id = url.searchParams.get('id') ?? '';
      if (!UUID.test(id)) throw new HttpError(400, 'bad_request', 'Unknown friend.');
      await rpc('app_remove_friend', { p_user: viewer, p_friend: id });
      return json(200, { ok: true });
    }
    if (route === 'POST /logout') {
      await rpc('app_logout', { p_hash: hash });
      return json(200, { ok: true });
    }
    if (route === 'DELETE /account') {
      await rpc('app_delete_account', { p_user: viewer });
      tokenCache.delete(viewer);
      return json(200, { ok: true });
    }
    throw new HttpError(404, 'not_found', 'Unknown endpoint.');
  } catch (e) {
    if (e instanceof HttpError) return json(e.status, { error: e.code, message: e.message });
    console.error(e);
    return json(500, { error: 'server_error', message: 'Something went wrong on the server.' });
  }
});
