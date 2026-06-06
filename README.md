# fitbit-air-poll

Periodic ingest of Fitbit Air data via the **Google Health API** (`health.googleapis.com/v4`).

Fitbit Air is a Google device and is **not** accessible through the legacy Fitbit Web API (which Google is turning down in September 2026). All access goes through the Google Health API with Google OAuth 2.0.

## What's in here

| File | Purpose |
|---|---|
| `auth-url.sh` | One-shot OAuth login. Opens the consent screen, accepts a pasted redirect URL, exchanges the code for tokens, writes them to `.token`. |
| `refresh-token-only.sh` | Uses `REFRESH_TOKEN` to mint a fresh `ACCESS_TOKEN` (~1h lifetime). Just the refresh, no side effects. |
| `refresh-token.sh` | Cron entry point: runs `refresh-token-only.sh`, then the data-lag snapshot experiment. |
| `snapshot-health-data.sh` | Data-lag experiment: snapshots yesterday+today into `data-experiment/<run-timestamp>/` so repeated pulls can be diffed for late-arriving data. |
| `analyze_experiment_deltas.py` | Diffs consecutive snapshot runs: reports added/changed/removed points and availability-lag stats per data type. |
| `fetch-health-data.sh` | Pulls a day's worth of heart-rate, steps, exercise, and sleep into `data/YYYY-MM-DD/*.json`. Auto-refreshes the access token if it's near expiry. |
| `get-recent-health-info.sh` | Live markdown summary to stdout: today's steps, last 7 days of exercise sessions, latest weight reading. |
| `log-weight.sh` | Writes a weight measurement (kg or lb, optional note) timestamped "now". |
| `log-food.sh` | Logs a food entry (name, kcal, meal type, optional protein/carbs/fat). |
| `crontab.txt` | The `crontab -e` line for keeping the access token alive (`*/30`). |
| `.env` | `CLIENT_ID` + `CLIENT_SECRET` (gitignored). |
| `.token` | `ACCESS_TOKEN`, `REFRESH_TOKEN`, `ACCESS_TOKEN_EXPIRES_AT` (gitignored, chmod 600). |
| `refresh-token.log` | Cron output (gitignored). |
| `data/` | Daily ingest output (gitignored). |
| `data-experiment/` | Snapshot-experiment output, one folder per run (gitignored). |

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
*/30 * * * * /home/dave/dev/fitbit-air-poll/refresh-token.sh >> /home/dave/dev/fitbit-air-poll/refresh-token.log 2>&1
```

Note `refresh-token.sh` also runs the data-lag snapshot experiment after each refresh (see below). If you only want the token kept alive, point the cron line at `refresh-token-only.sh` instead.

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

Get a quick live summary (markdown on stdout, progress on stderr):
```bash
./get-recent-health-info.sh
```
Shows today's steps (device-civil day — the fetch window is widened and post-filtered because the device timezone can differ from this machine's), the last 7 days of exercise sessions, and the most recent weight reading from the last 90 days.

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
./log-food.sh "Pancakes" 520 breakfast --date 2026-06-04    # backfill a past day
```

Meal types: `breakfast`, `lunch`, `dinner`, `snack`, `anytime` (default), plus the API's `before_*`/`after_*` variants. Named meals are back-stamped to a typical time of day (breakfast 08:00, lunch 12:30, dinner 18:30, `before_*` 30 min earlier, `after_dinner` 20:30; 15-minute intervals), so logging after the fact lands at a sensible time; `--date YYYY-MM-DD` applies them to a past day for backfilling (snack/anytime backfills land at 12:00; without `--date` they log at "now"). Both scripts POST to `users/me/dataTypes/{weight|nutrition-log}/dataPoints` and need the write scopes from setup step 1. Note the writeonly scopes can only edit/delete entries this app created — not ones logged from the Fitbit app.

See `AGENT_LOGGING_README.md` for a self-contained guide to the write API (auth, schemas, docs-vs-reality gotchas) aimed at AI agents / external tooling.

A successful write returns the created data point, including its full `name` (`users/{id}/dataTypes/{type}/dataPoints/{id}`) — keep it if you want to `patch` or delete the entry later.

## Data-lag experiment

The device→phone→Google Health sync chain means a pull can see incomplete data that's revised later. To measure that:

- `snapshot-health-data.sh` (run by `refresh-token.sh` every 30 min via cron) snapshots yesterday+today into `data-experiment/<run-start-timestamp>/`.
- `analyze_experiment_deltas.py` diffs consecutive runs and reports, per civil day and data type, ADDED / CHANGED / REMOVED points plus availability-lag percentiles (device sample time → first snapshot containing the point).

```bash
./analyze_experiment_deltas.py [--dir data-experiment] [--verbose]
```

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

- **`dataSource` docs are wrong for writes**: the reference docs list `recordingMethod: ACTIVELY_RECORDED` and an `application.name` field, but the live API rejects both (`INVALID_ARGUMENT`). Observed-valid `recordingMethod` values: `MANUAL` (what the log scripts use), `DERIVED`, `PASSIVELY_MEASURED`. The `application` and `platform` fields are server-populated from your OAuth client (`platform: GOOGLE_WEB_API`) — don't send them.
- **OAuth scope bleed**: do **not** pass `include_granted_scopes=true` on the auth URL. If your OAuth client has other Google scopes registered (e.g. Nest / `sdm_service`), the resulting token will be rejected by the Health API with `DISALLOWED_OAUTH_SCOPES`.
- **Rate limits**: 300 req/min per user, 120k req/min and 86.4M req/day per project. Daily ingest is nowhere near these.
- **Page-size caps**: `exercise` and `sleep` cap at 25/page (the script paginates). `heart-rate` and `steps` allow up to 10,000.
- **Rotate `CLIENT_SECRET` cleanly**: Cloud Console → APIs & Services → Credentials → your client → **Add secret** (gives you an overlap window), update `.env`, then delete the old one. Existing refresh tokens stay valid.

## References

- Google Health API docs: <https://developers.google.com/health>
- OAuth scopes: <https://developers.google.com/health/scopes>
- `dataPoints.list` endpoint: <https://developers.google.com/health/reference/rest/v4/users.dataTypes.dataPoints/list>
- Rate limits: <https://developers.google.com/health/rate-limits>
