#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Usage: ./log-weight.sh <weight> [kg|lb] ["notes"]
#   ./log-weight.sh 81.6
#   ./log-weight.sh 180 lb "after morning run"
# Sample time is "now" (local clock; UTC offset preserved).
# Requires the googlehealth.health_metrics_and_measurements.writeonly scope.

WEIGHT="${1:?Usage: ./log-weight.sh <weight> [kg|lb] [\"notes\"]}"
UNIT="${2:-kg}"
NOTES="${3:-}"

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

BODY=$(python3 - "$WEIGHT" "$UNIT" "$NOTES" <<'PY'
import datetime, json, sys

weight, unit, notes = float(sys.argv[1]), sys.argv[2].lower(), sys.argv[3]
if unit in ("kg", "kgs"):
    grams = weight * 1000
elif unit in ("lb", "lbs"):
    grams = weight * 453.59237
else:
    sys.exit(f"Unknown unit {unit!r} — use kg or lb.")

now = datetime.datetime.now().astimezone()
offset = int(now.utcoffset().total_seconds())

weight_obj = {
    "sampleTime": {
        "physicalTime": now.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "utcOffset": f"{offset}s",
    },
    "weightGrams": round(grams),
}
if notes:
    weight_obj["notes"] = notes

print(json.dumps({
    # The API rejects the documented ACTIVELY_RECORDED / application.name —
    # observed-valid enum values are MANUAL, DERIVED, PASSIVELY_MEASURED.
    "dataSource": {"recordingMethod": "MANUAL"},
    "weight": weight_obj,
}))
PY
)

URL="https://health.googleapis.com/v4/users/me/dataTypes/weight/dataPoints"
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

echo "Logged ${WEIGHT} ${UNIT}."
cat "$TMP"
echo
