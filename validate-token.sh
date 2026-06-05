#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .token ]]; then
  set -a; source .token; set +a
fi

: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN in .token — run ./auth-url.sh first}"

# Probe an endpoint covered by the requested scopes: list 1 steps dataPoint
# from the last 24h (activity_and_fitness.readonly).
read -r AGO_UTC NOW_UTC <<<"$(python3 -c "
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
ago = now - datetime.timedelta(days=1)
fmt = '%Y-%m-%dT%H:%M:%SZ'
print(ago.strftime(fmt), now.strftime(fmt))
")"

URL="https://health.googleapis.com/v4/users/me/dataTypes/steps/dataPoints"
FILTER="steps.interval.start_time >= \"${AGO_UTC}\" AND steps.interval.start_time < \"${NOW_UTC}\""

echo "Validating token against Google Health API…"
echo "  GET ${URL}  (steps, last 24h, pageSize=1)"

TMP_BODY=$(mktemp)
trap 'rm -f "$TMP_BODY"' EXIT

HTTP_CODE=$(curl -sS -o "$TMP_BODY" -w "%{http_code}" \
  --get \
  --data-urlencode "filter=${FILTER}" \
  --data-urlencode "pageSize=1" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "$URL")

echo "  HTTP $HTTP_CODE"
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$TMP_BODY" 2>/dev/null || cat "$TMP_BODY"
else
  cat "$TMP_BODY"
fi
echo

if [[ "$HTTP_CODE" != "200" ]]; then
  echo "Token validation failed (expected HTTP 200)." >&2
  exit 1
fi
echo "Token works."
