# Rotation

Spotify stats for you and your friends: top artists, tracks, albums and genres over 4 weeks, 6 months and 12 months, a listening clock, recent plays, what friends are playing right now, and a taste match between friends.

## How it fits together

- `index.html` is the whole frontend: one static page, no build step. Hosted on Vercel.
- `supabase/functions/api/index.ts` is the backend: a Supabase Edge Function (deployed with JWT verification off, because it checks its own session tokens).
- `supabase/migrations/` is the database. Every table has row level security on and no policies, and the `anon` and `authenticated` roles have no access, so only the edge function (using the project's secret key) can read or write anything.

Login uses Spotify's Authorization Code flow with PKCE, run entirely on the backend:

1. The page sends a random nonce to `POST /auth/start` and gets back a Spotify login URL.
2. Spotify redirects to `GET /callback` on the backend, which exchanges the code, saves the user and their refresh token, and redirects back to the page with a one-time ticket.
3. The page trades the ticket plus its nonce for a session at `POST /auth/redeem`.

Because the redirect URI is the backend's URL, the Spotify app settings never need to change when the site moves to a new address.

## Settings

Stored in the `app_settings` table:

| key | value |
| --- | --- |
| `spotify_client_id` | Client ID from the Spotify Developer Dashboard |
| `spotify_redirect_uri` | `https://ohcfeqlcecvfxhnpmujr.supabase.co/functions/v1/api/callback` (must match the Spotify app exactly) |
| `app_origins` | Comma-separated list of sites allowed to start a login, such as `https://rotation-stats.vercel.app` |

## Adding a friend

Spotify keeps apps in Development Mode limited to 5 accounts, and the account that owns the app needs Premium.

1. In the Spotify Developer Dashboard, open the app, go to **User Management** and add your friend's name and the email of their Spotify account.
2. In Rotation, open **Invite friends** and send them the link.
3. They tap **Connect with Spotify**. You become friends automatically.

## Listening time

Spotify's API has no listening-time or play-count data, so Rotation logs plays itself:

- A pg_cron job (`rotation-collect-plays`) calls `POST /cron/collect` every 20 minutes. It's authenticated with the `cron_secret` value in `app_settings`, and it saves everyone's latest 50 plays into `plays` (with track details in `tracks`).
- Plays are also saved whenever someone's stats load.
- `app_history` turns the log into minutes for today, the last 7 days and the week before, a 14-day chart, a streak, most played tracks and artists, and plays by hour. `app_leaderboard` ranks you and your friends by listening time over the last 7 days.
- Minutes are estimates: Spotify timestamps a play when it ends, so each play counts as the shorter of the song's length and the time since the previous play ended.
- History only covers the time since someone joined. Spotify's "Extended streaming history" download could backfill older years later.

## Data and caching

- Top items are cached for an hour, recent plays for 5 minutes, now playing for 40 seconds. "Refresh stats" asks for anything older than 2 minutes.
- If Spotify fails, the last saved copy is shown with a note saying when it's from.
- Deleting an account removes the profile, tokens, sessions, friendships and cached stats.
