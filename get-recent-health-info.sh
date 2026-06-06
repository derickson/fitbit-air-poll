#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Pulls live data and prints a markdown summary to stdout:
#   - steps for today (device-local civil day)
#   - exercise sessions from the last 7 days
#   - most recent weight reading (last 90 days)
# Progress/diagnostics go to stderr so stdout stays clean markdown.
# Usage: ./get-recent-exercise.sh

if [[ -f .env ]];   then set -a; source .env;   set +a; fi
if [[ -f .token ]]; then set -a; source .token; set +a; fi

: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN in .token — run ./auth-url.sh first}"

# Auto-refresh if token expires within 2 minutes.
NOW=$(date +%s)
if [[ -n "${ACCESS_TOKEN_EXPIRES_AT:-}" && "$ACCESS_TOKEN_EXPIRES_AT" -lt $((NOW + 120)) ]]; then
  echo "Access token near expiry — refreshing…" >&2
  ./refresh-token-only.sh >/dev/null
  set -a; source .token; set +a
fi

# Date boundaries. Steps are fetched over a generous UTC window (machine-local
# day ± the possible device offset) and then post-filtered to the device-civil
# day, because the device timezone can differ from this machine's. Exercise
# uses civil-date filters directly; weight looks back 90 days.
read -r TODAY TOMORROW WEEK_AGO STEPS_START_UTC STEPS_END_UTC WEIGHT_SINCE_UTC <<<"$(python3 -c "
import datetime
today = datetime.date.today()
fmt = '%Y-%m-%dT%H:%M:%SZ'
def utc(d, days=0):
    local = datetime.datetime(d.year, d.month, d.day).astimezone()
    return (local.astimezone(datetime.timezone.utc) + datetime.timedelta(days=days)).strftime(fmt)
print(today.isoformat(),
      (today + datetime.timedelta(days=1)).isoformat(),
      (today - datetime.timedelta(days=6)).isoformat(),
      utc(today, -1), utc(today, 2), utc(today, -90))
")"

BASE="https://health.googleapis.com/v4/users/me/dataTypes"
TMPDIR_LOCAL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_LOCAL"' EXIT

# fetch_all <url-name> <filter> <page-size> — paginated GET, pages land in
# $TMPDIR_LOCAL/<url-name>-page-N.json (same pattern as fetch-health-data.sh).
fetch_all() {
  local url_name="$1" filter="$2" page_size="$3"
  local page=0 token=""
  while :; do
    page=$((page + 1))
    local args=(
      --get
      --data-urlencode "filter=${filter}"
      --data-urlencode "pageSize=${page_size}"
    )
    [[ -n "$token" ]] && args+=(--data-urlencode "pageToken=${token}")

    local out="$TMPDIR_LOCAL/${url_name}-page-${page}.json" http_code
    http_code=$(curl -sS -o "$out" -w "%{http_code}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${args[@]}" "${BASE}/${url_name}/dataPoints")

    if [[ "$http_code" != "200" ]]; then
      echo "ERROR ($http_code) fetching $url_name page $page:" >&2
      cat "$out" >&2; echo >&2
      return 1
    fi

    token=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("nextPageToken",""))' "$out")
    [[ -z "$token" ]] && break
  done
  echo "Fetched $url_name ($page page(s))" >&2
}

fetch_all "steps"    "steps.interval.start_time >= \"${STEPS_START_UTC}\" AND steps.interval.start_time < \"${STEPS_END_UTC}\"" 10000
fetch_all "exercise" "exercise.interval.civil_start_time >= \"${WEEK_AGO}\" AND exercise.interval.civil_start_time < \"${TOMORROW}\"" 25
fetch_all "weight"   "weight.sample_time.physical_time >= \"${WEIGHT_SINCE_UTC}\"" 10000

python3 - "$TODAY" "$WEEK_AGO" "$TMPDIR_LOCAL" <<'PY'
import datetime, glob, json, sys

today, week_ago, tmpdir = sys.argv[1], sys.argv[2], sys.argv[3]

def load(name):
    pts = []
    for f in sorted(glob.glob(f"{tmpdir}/{name}-page-*.json")):
        pts += json.load(open(f)).get("dataPoints", [])
    return pts

def civil_hm(c):
    t = c.get("time", {})
    return f"{t.get('hours', 0):02d}:{t.get('minutes', 0):02d}"

def civil_date(c):
    d = c["date"]
    return datetime.date(d["year"], d["month"], d["day"])

def dur_str(seconds):
    m = round(seconds / 60)
    return f"{m // 60}h {m % 60:02d}m" if m >= 60 else f"{m}m"

# ---- Steps today -----------------------------------------------------------
# Post-filter to the device-civil day: the fetch window is deliberately wider
# than one day because the device timezone may differ from this machine's.
steps_pts = [p["steps"] for p in load("steps") if "steps" in p]
steps_pts = [s for s in steps_pts
             if civil_date(s["interval"]["civilStartTime"]).isoformat() == today]
total = sum(int(s.get("count", 0)) for s in steps_pts)
by_hour = {}
for s in steps_pts:
    h = s["interval"].get("civilStartTime", {}).get("time", {}).get("hours", 0)
    by_hour[h] = by_hour.get(h, 0) + int(s.get("count", 0))

print(f"# Recent activity — {today}\n")
print(f"## Steps today\n")
print(f"**Total: {total:,} steps**", end="")
if steps_pts:
    first = min(civil_hm(s["interval"]["civilStartTime"]) for s in steps_pts)
    last  = max(civil_hm(s["interval"]["civilEndTime"])   for s in steps_pts)
    busiest = max(by_hour, key=by_hour.get)
    print(f" across {len(steps_pts)} active minutes ({first}–{last}, device-local time)\n")
    print(f"Busiest hour: {busiest:02d}:00–{busiest + 1:02d}:00 with {by_hour[busiest]:,} steps")
else:
    print("\n\n_No steps recorded yet today (device may not have synced)._")

# ---- Exercise sessions, last 7 days ---------------------------------------
sessions = [p["exercise"] for p in load("exercise") if "exercise" in p]
sessions.sort(key=lambda e: e["interval"]["startTime"], reverse=True)

print(f"\n## Exercise sessions — last 7 days ({week_ago} → {today})\n")
if not sessions:
    print("_No exercise sessions in this window._")
else:
    print("| Date | Activity | Start | Duration | Distance | Calories | Avg HR | Steps | AZM |")
    print("|---|---|---|---|---|---|---|---|---|")
    for e in sessions:
        iv, ms = e["interval"], e.get("metricsSummary", {})
        start_utc = datetime.datetime.strptime(iv["startTime"], "%Y-%m-%dT%H:%M:%SZ")
        offset = datetime.timedelta(seconds=int(iv.get("startUtcOffset", "0s").rstrip("s")))
        start_local = start_utc + offset
        dist_mm = ms.get("distanceMillimeters")
        dist = f"{dist_mm / 1e6:.2f} km" if dist_mm else "—"
        hr = ms.get("averageHeartRateBeatsPerMinute")
        print("| {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
            start_local.strftime("%a %Y-%m-%d"),
            e.get("displayName") or e.get("exerciseType", "?").replace("_", " ").title(),
            start_local.strftime("%H:%M"),
            dur_str(int(e.get("activeDuration", "0s").rstrip("s"))),
            dist,
            ms.get("caloriesKcal", "—"),
            f"{hr} bpm" if hr else "—",
            f"{int(ms['steps']):,}" if ms.get("steps") else "—",
            ms.get("activeZoneMinutes", "—"),
        ))
    n = len(sessions)
    total_min = sum(int(e.get("activeDuration", "0s").rstrip("s")) for e in sessions) / 60
    total_kcal = sum(ms.get("caloriesKcal", 0) for ms in (e.get("metricsSummary", {}) for e in sessions))
    total_km = sum(ms.get("distanceMillimeters", 0) for ms in (e.get("metricsSummary", {}) for e in sessions)) / 1e6
    print(f"\n**{n} session(s)** · {dur_str(total_min * 60)} active · {total_km:.1f} km · {total_kcal:,} kcal")

# ---- Latest weight ---------------------------------------------------------
weights = [p["weight"] for p in load("weight") if "weight" in p]
print("\n## Latest weight\n")
if not weights:
    print("_No weight readings in the last 90 days._")
else:
    w = max(weights, key=lambda w: w["sampleTime"]["physicalTime"])
    grams = float(w["weightGrams"])
    when_utc = datetime.datetime.strptime(w["sampleTime"]["physicalTime"], "%Y-%m-%dT%H:%M:%SZ")
    offset = datetime.timedelta(seconds=int(w["sampleTime"].get("utcOffset", "0s").rstrip("s")))
    when = (when_utc + offset).strftime("%a %Y-%m-%d %H:%M")
    note = f' — "{w["notes"]}"' if w.get("notes") else ""
    print(f"**{grams / 1000:.1f} kg ({grams / 453.59237:.1f} lb)** measured {when}{note}")
PY
