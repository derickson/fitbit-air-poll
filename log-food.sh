#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Usage: ./log-food.sh "<food name>" <kcal> [meal] [--date YYYY-MM-DD]
#                      [--protein G] [--carbs G] [--fat G]
#   ./log-food.sh "Chicken burrito" 650 lunch --protein 35 --carbs 70 --fat 22
#   ./log-food.sh "Apple" 95 snack
#   ./log-food.sh "Pancakes" 520 breakfast --date 2026-06-04   # backfill
# meal: breakfast | lunch | dinner | snack | anytime (default) — plus the
#       BEFORE_*/AFTER_* variants the API accepts.
# Timestamping: named meals are back-stamped to their typical time of day
# (local clock): breakfast 08:00, lunch 12:30, dinner 18:30, before_* 30 min
# earlier, after_dinner 20:30 — so you can log a meal after the fact and it
# lands at a sensible time. --date applies those times to a past day for
# backfilling (defaults to today). snack/anytime log at "now" today, or at
# 12:00 on a backfilled day. If a typical time hasn't happened yet today,
# "now" is used.
# Requires the googlehealth.nutrition.writeonly scope.

FOOD="${1:?Usage: ./log-food.sh \"<food name>\" <kcal> [meal] [--protein G] [--carbs G] [--fat G]}"
KCAL="${2:?Missing kcal}"
shift 2

MEAL="ANYTIME"
if [[ $# -gt 0 && "$1" != --* ]]; then
  MEAL="$1"
  shift
fi

PROTEIN="" CARBS="" FAT="" DATE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protein) PROTEIN="$2"; shift 2 ;;
    --carbs)   CARBS="$2";   shift 2 ;;
    --fat)     FAT="$2";     shift 2 ;;
    --date)    DATE="$2";    shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -f .env ]];   then set -a; source .env;   set +a; fi
if [[ -f .token ]]; then set -a; source .token; set +a; fi

: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN in .token — run ./auth-url.sh first}"

# Auto-refresh if token expires within 2 minutes.
NOW=$(date +%s)
if [[ -n "${ACCESS_TOKEN_EXPIRES_AT:-}" && "$ACCESS_TOKEN_EXPIRES_AT" -lt $((NOW + 120)) ]]; then
  echo "Access token near expiry — refreshing…"
  ./refresh-token-only.sh >/dev/null
  set -a; source .token; set +a
fi

BODY=$(python3 - "$FOOD" "$KCAL" "$MEAL" "$PROTEIN" "$CARBS" "$FAT" "$DATE" <<'PY'
import datetime, json, sys

food, kcal, meal, protein, carbs, fat, date_arg = sys.argv[1:8]

meal = meal.upper()
# Typical local time of day per meal, for back-stamping after-the-fact logs.
# None → log at "now". (API requires start < end strictly, so every entry
# gets a short interval rather than an instant.)
meal_times = {
    "BEFORE_BREAKFAST": "07:30",
    "BREAKFAST":        "08:00",
    "BEFORE_LUNCH":     "12:00",
    "LUNCH":            "12:30",
    "BEFORE_DINNER":    "18:00",
    "DINNER":           "18:30",
    "AFTER_DINNER":     "20:30",
    "SNACK":            None,
    "ANYTIME":          None,
}
if meal not in meal_times:
    sys.exit(f"Unknown meal {meal!r} — one of: {', '.join(sorted(meal_times))}")

now = datetime.datetime.now().astimezone()
offset = f"{int(now.utcoffset().total_seconds())}s"
fmt = "%Y-%m-%dT%H:%M:%SZ"

# --date for backfilling; defaults to today.
if date_arg:
    try:
        target = datetime.date.fromisoformat(date_arg)
    except ValueError:
        sys.exit(f"Invalid --date {date_arg!r} — use YYYY-MM-DD.")
    if target > now.date():
        sys.exit(f"--date {date_arg} is in the future.")
else:
    target = now.date()
backfill = target != now.date()

assumed = meal_times[meal]
if not assumed and backfill:
    assumed = "12:00"  # snack/anytime on a past day: midday
if assumed:
    h, m = map(int, assumed.split(":"))
    start = now.replace(year=target.year, month=target.month, day=target.day,
                        hour=h, minute=m, second=0, microsecond=0)
    end = start + datetime.timedelta(minutes=15)
    if start > now:  # typical time hasn't happened yet today — fall back to now
        print(f"[log-food] {meal} time {assumed} is in the future; logging at now instead", file=sys.stderr)
        assumed = None
if not assumed:
    start = now - datetime.timedelta(minutes=1)
    end = now

start_ts = start.astimezone(datetime.timezone.utc).strftime(fmt)
end_ts   = end.astimezone(datetime.timezone.utc).strftime(fmt)

log = {
    "interval": {
        "startTime": start_ts, "startUtcOffset": offset,
        "endTime": end_ts,     "endUtcOffset": offset,
    },
    "foodDisplayName": food,
    "mealType": meal,
    "energy": {"kcal": float(kcal)},
}
if carbs:
    log["totalCarbohydrate"] = {"grams": float(carbs)}
if fat:
    log["totalFat"] = {"grams": float(fat)}
if protein:
    log["nutrients"] = [{"nutrient": "PROTEIN", "quantity": {"grams": float(protein)}}]

print(json.dumps({
    # The API rejects the documented ACTIVELY_RECORDED / application.name —
    # observed-valid enum values are MANUAL, DERIVED, PASSIVELY_MEASURED.
    "dataSource": {"recordingMethod": "MANUAL"},
    "nutritionLog": log,
}))
PY
)

URL="https://health.googleapis.com/v4/users/me/dataTypes/nutrition-log/dataPoints"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

HTTP_CODE=$(curl -sS -o "$TMP" -w "%{http_code}" -X POST \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$BODY" "$URL")

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "ERROR ($HTTP_CODE):" >&2
  cat "$TMP" >&2
  echo >&2
  exit 1
fi

echo "Logged \"${FOOD}\" (${KCAL} kcal, ${MEAL}, ${DATE:-today})."
cat "$TMP"
echo
