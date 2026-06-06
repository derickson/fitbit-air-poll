# fitbit-air-poll

Periodic ingest of Fitbit Air data via the **Google Health API** (`health.googleapis.com/v4`).

Fitbit Air is a Google device and is **not** accessible through the legacy Fitbit Web API (which Google is turning down in September 2026). All access goes through the Google Health API with Google OAuth 2.0.

## What's in here

| File | Purpose |
|---|---|
| `auth-url.sh` | One-shot OAuth login. Opens the consent screen, accepts a pasted redirect URL, exchanges the code for tokens, writes them to `.token`. |
| `refresh-token.sh` | Uses `REFRESH_TOKEN` to mint a fresh `ACCESS_TOKEN` (~1h lifetime). Designed for cron. |
| `fetch-health-data.sh` | Pulls a day's worth of heart-rate, steps, exercise, and sleep into `data/YYYY-MM-DD/*.json`. Auto-refreshes the access token if it's near expiry. |
| `log-weight.sh` | Writes a weight measurement (kg or lb, optional note) timestamped "now". |
| `log-food.sh` | Logs a food entry (name, kcal, meal type, optional protein/carbs/fat). |
| `crontab.txt` | The `crontab -e` line for keeping the access token alive (`*/30`). |
| `.env` | `CLIENT_ID` + `CLIENT_SECRET` (gitignored). |
| `.token` | `ACCESS_TOKEN`, `REFRESH_TOKEN`, `ACCESS_TOKEN_EXPIRES_AT` (gitignored, chmod 600). |
| `refresh-token.log` | Cron output (gitignored). |
| `data/` | Daily ingest output. |

## One-time setup

### 1. Google Cloud project

- Enable the API: <https://console.cloud.google.com/apis/library/health.googleapis.com>
- Create an OAuth 2.0 **Web Server** client. Set redirect URI to `https://www.google.com`.
- In **OAuth consent screen → Audience**, click **Publish app** so refresh tokens don't expire after 7 days. (Verification is not required for personal use under the 100-user cap.)
- In **Data Access**, enable these scopes:
  - `https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly`
  - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly`
  - `https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly` (write weight/body measurements)
  - `https://www.googleapis.com/auth/googlehealth.nutrition.readonly` (read food logs)
  - `https://www.googleapis.com/auth/googlehealth.nutrition.writeonly` (log food)
  - `https://www.googleapis.com/auth/googlehealth.sleep.readonly`

### 2. Create `.env`

Create a file named `.env` in the project root containing your OAuth client credentials (you can copy these from the Cloud Console → APIs & Services → Credentials page):

```
CLIENT_ID=xxxxx.apps.googleusercontent.com
CLIENT_SECRET=GOCSPX-xxxxx
```

Required variables:

| Variable | Where it comes from |
|---|---|
| `CLIENT_ID` | OAuth 2.0 Client ID from the Cloud Console |
| `CLIENT_SECRET` | Client secret for that same OAuth client |

The `.env` file is gitignored. **Do not commit it.** Nothing else belongs in `.env` — `ACCESS_TOKEN` / `REFRESH_TOKEN` are managed automatically in a separate `.token` file (also gitignored, chmod 600).

### 3. First run — get your tokens

Run the OAuth login script:

```bash
./auth-url.sh
```

What happens:
1. Your default browser opens to the Google consent screen.
2. Sign in (as the Google account that owns the Fitbit Air) and approve the requested scopes.
3. Google redirects to `https://www.google.com/?code=…` — that page will look empty/blank, that's expected.
4. **Copy the full URL** from your browser's address bar and paste it into the terminal where the script is waiting. Press Enter.
5. The script exchanges the code for tokens and writes them to `.token`.

You should see output ending with:
```
Saved tokens to .token (chmod 600).
  access_token expires in 3599s
  refresh_token: (persistent)
```

- `refresh_token: (persistent)` → you're set; the refresh token won't expire on its own.
- `refresh_token: expires in 604800s — app is in Testing mode` → your OAuth client isn't published yet. Go back to **OAuth consent screen → Audience** and click **Publish app**, then re-run `./auth-url.sh`.

Smoke-test that the token actually works against the Health API:

```bash
source .token && curl -sS -H "Authorization: Bearer $ACCESS_TOKEN" \
  https://health.googleapis.com/v4/users/me/pairedDevices
```

You should see your Fitbit Air listed.

### 4. Install the cron job (keeps the access token valid)

Access tokens expire after ~1 hour. `refresh-token.sh` uses the long-lived refresh token to mint a new access token. To run it automatically every 30 minutes:

```bash
crontab -e
```

Paste this line (also kept in `crontab.txt` for reference) and save:

```
*/30 * * * * /Users/dave/dev/fitbit-air-poll/refresh-token.sh >> /Users/dave/dev/fitbit-air-poll/refresh-token.log 2>&1
```

Verify it's installed:

```bash
crontab -l
```

Why `*/30`: tokens live 60 minutes, so refreshing every 30 means a single missed cron run still leaves a valid token. Output (success line or error JSON) goes to `refresh-token.log` (gitignored) so you can troubleshoot.

**macOS gotcha:** the first time cron runs the script, macOS may prompt for Full Disk Access for `/usr/sbin/cron` (System Settings → Privacy & Security → Full Disk Access).

The cron job is optional for one-off use — `fetch-health-data.sh` will also refresh the token on-demand if it sees it's about to expire. The cron job mainly matters if you want `ACCESS_TOKEN` to be valid for ad-hoc `curl` calls without thinking about it.

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

### Writing data

Log a weight measurement (timestamped "now"):
```bash
./log-weight.sh 81.6              # kg by default
./log-weight.sh 180 lb "after morning run"
```

Log a food entry:
```bash
./log-food.sh "Apple" 95 snack
./log-food.sh "Chicken burrito" 650 lunch --protein 35 --carbs 70 --fat 22
```

Meal types: `breakfast`, `lunch`, `dinner`, `snack`, `anytime` (default), plus the API's `before_*`/`after_*` variants. Both scripts POST to `users/me/dataTypes/{weight|nutrition-log}/dataPoints` and need the write scopes from setup step 1. Note the writeonly scopes can only edit/delete entries this app created — not ones logged from the Fitbit app.

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
