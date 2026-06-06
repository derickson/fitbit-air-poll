#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Usage: ./log-food.sh "<food name>" <kcal> [meal] [--protein G] [--carbs G] [--fat G]
#   ./log-food.sh "Chicken burrito" 650 lunch --protein 35 --carbs 70 --fat 22
#   ./log-food.sh "Apple" 95 snack
# meal: breakfast | lunch | dinner | snack | anytime (default) — plus the
#       BEFORE_*/AFTER_* variants the API accepts.
# Logged at "now" (local clock; UTC offset preserved).
# Requires the googlehealth.nutrition.writeonly scope.

FOOD="${1:?Usage: ./log-food.sh \"<food name>\" <kcal> [meal] [--protein G] [--carbs G] [--fat G]}"
KCAL="${2:?Missing kcal}"
shift 2

MEAL="ANYTIME"
if [[ $# -gt 0 && "$1" != --* ]]; then
  MEAL="$1"
  shift
fi

PROTEIN="" CARBS="" FAT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --protein) PROTEIN="$2"; shift 2 ;;
    --carbs)   CARBS="$2";   shift 2 ;;
    --fat)     FAT="$2";     shift 2 ;;
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

BODY=$(python3 - "$FOOD" "$KCAL" "$MEAL" "$PROTEIN" "$CARBS" "$FAT" <<'PY'
import datetime, json, sys

food, kcal, meal, protein, carbs, fat = sys.argv[1:7]

meal = meal.upper()
valid_meals = {"BEFORE_BREAKFAST", "BREAKFAST", "BEFORE_LUNCH", "LUNCH",
               "BEFORE_DINNER", "DINNER", "AFTER_DINNER", "SNACK", "ANYTIME"}
if meal not in valid_meals:
    sys.exit(f"Unknown meal {meal!r} — one of: {', '.join(sorted(valid_meals))}")

now = datetime.datetime.now().astimezone()
ts = now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
offset = f"{int(now.utcoffset().total_seconds())}s"

log = {
    "interval": {
        "startTime": ts, "startUtcOffset": offset,
        "endTime": ts,   "endUtcOffset": offset,
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

echo "Logged \"${FOOD}\" (${KCAL} kcal, ${MEAL})."
cat "$TMP"
echo
