# Agent guide: logging weight & food to Google Health (Fitbit Air)

Audience: an AI agent (or any program) that needs to write weight measurements
and food logs to this user's Google Health account, and read them back. All
facts below were verified live against the API in June 2026 — where the
official docs disagree with reality, that is called out explicitly.

## TL;DR — two ways to log

**1. If you have shell access to this repo**, use the scripts (they handle
auth, token refresh, units, and timestamps):

```bash
./log-weight.sh 234 lb "after morning run"     # or: ./log-weight.sh 81.6  (kg default)
./log-food.sh "Chicken burrito" 650 lunch --protein 35 --carbs 70 --fat 22
./log-food.sh "Apple" 95 snack
./log-food.sh "Pancakes" 520 breakfast --date 2026-06-04   # backfill a past day
./get-recent-health-info.sh                    # markdown summary: steps/exercise/weight
```

**2. If you only have HTTP**, follow the "Raw API" section below.

## Authentication

- OAuth 2.0 (Google). Client credentials live in `.env` (`CLIENT_ID`,
  `CLIENT_SECRET`); user tokens live in `.token` (`ACCESS_TOKEN`,
  `REFRESH_TOKEN`, `ACCESS_TOKEN_EXPIRES_AT` — unix epoch seconds). Both files
  are gitignored; `.token` is chmod 600.
- Access tokens last ~1 hour. Refresh before use if
  `ACCESS_TOKEN_EXPIRES_AT < now + 120`:
  - script: `./refresh-token-only.sh` (rewrites `.token`; no side effects)
  - raw: `POST https://oauth2.googleapis.com/token` with form fields
    `client_id`, `client_secret`, `refresh_token`, `grant_type=refresh_token`.
    Response has `access_token` + `expires_in`. The refresh token normally
    does NOT rotate, but persist `refresh_token` from the response if present.
- A cron job also refreshes every 30 min via `fitbit-poll.sh` (which
  additionally fetches recent data and ingests it into Elasticsearch — do
  not use that one for on-demand refresh; use `refresh-token-only.sh`).

### Required OAuth scopes (already granted on the current refresh token)

| Action | Scope (`https://www.googleapis.com/auth/` prefix) |
|---|---|
| write weight | `googlehealth.health_metrics_and_measurements.writeonly` |
| read weight | `googlehealth.health_metrics_and_measurements.readonly` |
| write food | `googlehealth.nutrition.writeonly` |
| read food | `googlehealth.nutrition.readonly` |

`writeonly` scopes can edit/delete **only data points this OAuth client
created** — entries logged from the Fitbit app itself are read-only to us.

## Raw API

Base: `https://health.googleapis.com/v4/users/me/dataTypes`
Header: `Authorization: Bearer <ACCESS_TOKEN>`, `Content-Type: application/json`

Data-type names are **kebab-case in URLs** (`weight`, `nutrition-log`) but
**snake_case in filter expressions** (`weight.sample_time...`).

### Write a weight measurement

`POST {base}/weight/dataPoints`

```json
{
  "dataSource": {"recordingMethod": "MANUAL"},
  "weight": {
    "sampleTime": {
      "physicalTime": "2026-06-06T21:00:00Z",
      "utcOffset": "-14400s"
    },
    "weightGrams": 106141,
    "notes": "optional free text"
  }
}
```

- `weightGrams`: integer grams. lb → grams: multiply by 453.59237.
- `physicalTime`: RFC-3339 **UTC**. `utcOffset`: proto Duration string
  (seconds + `"s"`) for the user's local offset; the server derives the
  displayed `civilTime` from `physicalTime + utcOffset`.
- Response: `{"done": true, "response": {...the created DataPoint...}}`. Save
  `response.name` (`users/{uid}/dataTypes/weight/dataPoints/{id}`) if you may
  need to patch/delete later.

### Write a food log

`POST {base}/nutrition-log/dataPoints`

```json
{
  "dataSource": {"recordingMethod": "MANUAL"},
  "nutritionLog": {
    "interval": {
      "startTime": "2026-06-06T12:30:00Z", "startUtcOffset": "-14400s",
      "endTime":   "2026-06-06T12:45:00Z", "endUtcOffset":   "-14400s"
    },
    "foodDisplayName": "Chicken burrito",
    "mealType": "LUNCH",
    "energy": {"kcal": 650},
    "totalCarbohydrate": {"grams": 70},
    "totalFat": {"grams": 22},
    "nutrients": [{"nutrient": "PROTEIN", "quantity": {"grams": 35}}]
  }
}
```

- **`startTime` must be strictly earlier than `endTime`** or you get
  `INVALID_TIME_RANGE`. An instantaneous log is rejected; use a short
  interval (the scripts use 15 min for meals, 1 min for snacks).
- `mealType` enum: `BEFORE_BREAKFAST`, `BREAKFAST`, `BEFORE_LUNCH`, `LUNCH`,
  `BEFORE_DINNER`, `DINNER`, `AFTER_DINNER`, `SNACK`, `ANYTIME`.
- Energy is kcal; carbs/fat have dedicated fields; protein (and FIBER, SUGAR,
  SODIUM, …) go in the `nutrients` array as `{"nutrient": ENUM, "quantity":
  {"grams": N}}`.
- Only `energy` + `foodDisplayName` + `mealType` + `interval` are needed for a
  minimal entry; macros are optional.

### ⚠ Where the official docs are WRONG (verified live)

1. `dataSource.recordingMethod`: docs say `ACTIVELY_RECORDED` — the API
   rejects it (`INVALID_ARGUMENT`). Use **`MANUAL`** for agent-logged data.
   Other values observed in device data: `DERIVED`, `PASSIVELY_MEASURED`.
2. `dataSource.application`: docs describe a settable `name` field — the API
   rejects it (`Unknown name "name"`). Do not send `application` or
   `platform`; the server fills them from your OAuth client
   (`platform: "GOOGLE_WEB_API"`, `application.googleWebClientId: ...`).

### Timestamp conventions used by the scripts

- `log-weight.sh`: stamps "now" (machine-local clock, offset preserved).
- `log-food.sh`: named meals are **back-stamped to a typical time of day**,
  so after-the-fact logging lands sensibly: breakfast 08:00, lunch 12:30,
  dinner 18:30, `before_*` 30 min earlier, after_dinner 20:30 — each as a
  15-minute interval. By default that's today; `--date YYYY-MM-DD` backfills
  a past day (future dates are rejected). `snack`/`anytime` log a 1-minute
  interval ending now, or 12:00 on a backfilled day. If the typical time is
  still in the future today, it falls back to "now". An agent backfilling
  whole days should pass `--date` plus the meal name and let the script pick
  times rather than computing timestamps itself.

### Read back

List with a filter (paginate via `nextPageToken`/`pageToken`):

```
GET {base}/weight/dataPoints?filter=weight.sample_time.physical_time >= "2026-03-01T00:00:00Z"&pageSize=10000
GET {base}/nutrition-log/dataPoints?filter=nutrition_log.interval.start_time >= "2026-06-01T00:00:00Z"&pageSize=100
```

(URL-encode the filter. Times in filters are RFC-3339 UTC.) Single point:
`GET https://health.googleapis.com/v4/{name}` using the saved `name`.

### Delete / amend

- Delete: `POST {base}/{dataType}/dataPoints:batchDelete` with
  `{"names": ["users/{uid}/dataTypes/{dataType}/dataPoints/{id}", ...]}`.
- Amend: `PATCH https://health.googleapis.com/v4/{name}` with a DataPoint body.
- Both work only on points this client created (see scopes above).

## Error handling cheat-sheet

| Symptom | Cause / fix |
|---|---|
| 401 `UNAUTHENTICATED` | Access token expired → refresh (see above). |
| 403 `DISALLOWED_OAUTH_SCOPES` | Token minted with scopes the Health API doesn't accept (e.g. scope bleed from `include_granted_scopes=true`). Re-auth cleanly. |
| 400 `INVALID_TIME_RANGE` | `startTime >= endTime` on an interval. Make start strictly earlier. |
| 400 `Invalid value at ...recording_method` | You used a docs-listed enum like `ACTIVELY_RECORDED`. Use `MANUAL`. |
| 400 `Unknown name "name" at ...application` | You sent `dataSource.application`. Remove it. |
| 500 `Internal error` | Often means field validation passed but the payload is semantically bad (e.g. zero/missing required sub-fields). Check the body against the examples here. |

## Rate limits

300 requests/min per user; far above anything an agent should need for
logging. Be a good citizen: one POST per meal/measurement, no polling loops
tighter than minutes.
