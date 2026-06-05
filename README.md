# fitbit-new

Periodic ingest of Fitbit Air data via the **Google Health API** (`health.googleapis.com/v4`).

Fitbit Air is a Google device and is **not** accessible through the legacy Fitbit Web API (which Google is turning down in September 2026). All access goes through the Google Health API with Google OAuth 2.0.

## What's in here

| File | Purpose |
|---|---|
| `auth-url.sh` | One-shot OAuth login. Opens the consent screen, accepts a pasted redirect URL, exchanges the code for tokens, writes them to `.token`. |
| `refresh-token.sh` | Uses `REFRESH_TOKEN` to mint a fresh `ACCESS_TOKEN` (~1h lifetime). Designed for cron. |
| `fetch-health-data.sh` | Pulls a day's worth of heart-rate, steps, exercise, and sleep into `data/YYYY-MM-DD/*.json`. Auto-refreshes the access token if it's near expiry. |
| `crontab.txt` | The `crontab -e` line for keeping the access token alive (`*/30`). |
| `.env` | `CLIENT_ID` + `CLIENT_SECRET` (gitignored). |
| `.token` | `ACCESS_TOKEN`, `REFRESH_TOKEN`, `ACCESS_TOKEN_EXPIRES_AT` (gitignored, chmod 600). |
| `refresh-token.log` | Cron output (gitignored). |
| `data/` | Daily ingest output. |

## One-time setup

1. **Google Cloud project**
   - Enable the API: <https://console.cloud.google.com/apis/library/health.googleapis.com>
   - Create an OAuth 2.0 **Web Server** client. Set redirect URI to `https://www.google.com`.
   - In **OAuth consent screen → Audience**, click **Publish app** so refresh tokens don't expire after 7 days. (Verification is not required for personal use under the 100-user cap.)
   - In **Data Access**, enable these scopes:
     - `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
     - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
     - `https://www.googleapis.com/auth/googlehealth.sleep.readonly`

2. **Local credentials** — put your client ID + secret in `.env`:
   ```
   CLIENT_ID=xxxxx.apps.googleusercontent.com
   CLIENT_SECRET=GOCSPX-xxxxx
   ```

3. **Authenticate**
   ```bash
   ./auth-url.sh
   ```
   Browser opens → consent → you're redirected to `https://www.google.com/?code=…`. Paste that full URL back into the terminal. Tokens land in `.token`.
   If the output says `refresh_token: (persistent)` you're good. `expires in 604800s` means your OAuth client is still in Testing mode — go publish it.

4. **Keep the token alive** (optional but recommended) — install the cron job:
   ```bash
   crontab -e
   # paste the line from crontab.txt
   ```
   This runs `refresh-token.sh` every 30 minutes; with a 60-minute access token lifetime, a single missed run still leaves a valid token.

## Usage

Pull yesterday's data:
```bash
./fetch-health-data.sh
```

Pull a specific date:
```bash
./fetch-health-data.sh 2026-06-01
```

Output layout:
```
data/2026-06-04/
├── heart-rate.json     # ~every 2.4s sample (~35k points/day, ~20MB)
├── steps.json          # per-minute step intervals
├── exercise.json       # logged workout sessions
└── sleep.json          # sleep sessions with stage breakdown (REM/DEEP/LIGHT/AWAKE)
```

Each file is `{ "dataPoints": [...], "pageCount": N }`. Pagination is handled transparently.

## API filter quirks (the part that took the longest)

The filter field path differs per data-type "kind":

| Data type | Kind | Filter field that works |
|---|---|---|
| `heart-rate` | Sample | `heart_rate.sample_time.physical_time` (RFC-3339 UTC) |
| `steps` | Interval | `steps.interval.start_time` (RFC-3339 UTC) |
| `exercise` | Session | `exercise.interval.civil_start_time` (civil date, e.g. `2026-06-04`) |
| `sleep` | Session | `sleep.interval.civil_end_time` (civil date — sleep is filtered by **end** time because sessions span midnight) |

Also: kebab-case in URL paths (`heart-rate`), snake_case in filter expressions (`heart_rate`).

## Gotchas

- **OAuth scope bleed**: do **not** pass `include_granted_scopes=true` on the auth URL. If your OAuth client has other Google scopes registered (e.g. Nest / `sdm_service`), the resulting token will be rejected by the Health API with `DISALLOWED_OAUTH_SCOPES`.
- **Rate limits**: 300 req/min per user, 120k req/min and 86.4M req/day per project. Daily ingest is nowhere near these.
- **Page-size caps**: `exercise` and `sleep` cap at 25/page (the script paginates). `heart-rate` and `steps` allow up to 10,000.
- **Rotate `CLIENT_SECRET` cleanly**: Cloud Console → APIs & Services → Credentials → your client → **Add secret** (gives you an overlap window), update `.env`, then delete the old one. Existing refresh tokens stay valid.

## References

- Google Health API docs: <https://developers.google.com/health>
- OAuth scopes: <https://developers.google.com/health/scopes>
- `dataPoints.list` endpoint: <https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list>
- Rate limits: <https://developers.google.com/health/rate-limits>
