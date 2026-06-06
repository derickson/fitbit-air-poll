#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Usage: ./fetch-health-data.sh [YYYY-MM-DD]
#   No arg → yesterday (full civil day in your local timezone).
DATE="${1:-$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=1)).isoformat())")}"
NEXT_DATE=$(python3 -c "import datetime; print((datetime.date.fromisoformat('$DATE') + datetime.timedelta(days=1)).isoformat())")

# Convert local-midnight boundaries to UTC RFC-3339 for the API filter.
read -r START_UTC END_UTC <<<"$(python3 -c "
import datetime
local = datetime.datetime.strptime('$DATE', '%Y-%m-%d').astimezone()
nxt   = local + datetime.timedelta(days=1)
fmt   = '%Y-%m-%dT%H:%M:%SZ'
print(local.astimezone(datetime.timezone.utc).strftime(fmt),
      nxt.astimezone(datetime.timezone.utc).strftime(fmt))
")"

if [[ -f .env ]];   then set -a; source .env;   set +a; fi
if [[ -f .token ]]; then set -a; source .token; set +a; fi

: "${ACCESS_TOKEN:?Missing ACCESS_TOKEN in .token — run ./auth-url.sh first}"

# Auto-refresh if token expires within 2 minutes.
NOW=$(date +%s)
if [[ -n "${ACCESS_TOKEN_EXPIRES_AT:-}" && "$ACCESS_TOKEN_EXPIRES_AT" -lt $((NOW + 120)) ]]; then
  echo "Access token near expiry — refreshing…"
  ./refresh-token.sh >/dev/null
  set -a; source .token; set +a
fi

# OUT_BASE override lets snapshot-health-data.sh redirect output into
# timestamped experiment folders; default remains data/.
OUT_DIR="${OUT_BASE:-data}/$DATE"
mkdir -p "$OUT_DIR"

BASE="https://health.googleapis.com/v4/users/me/dataTypes"

# kebab-case in URL, snake_case in filter. Time-field & value format differ:
#   Sample types  → <type>.sample_time.physical_time, RFC-3339 (UTC)
#   Interval types → <type>.interval.start_time,        RFC-3339 (UTC)
#   Session types  → <type>.interval.civil_start_time,  civil date (YYYY-MM-DD)
# Pipe-delimited: "url-name|filter-time-field|format(rfc3339|civil)|page-size"
DATA_TYPES=(
  "heart-rate|heart_rate.sample_time.physical_time|rfc3339|10000"
  "steps|steps.interval.start_time|rfc3339|10000"
  "exercise|exercise.interval.civil_start_time|civil|25"
  "sleep|sleep.interval.civil_end_time|civil|25"
)

fetch_type() {
  local url_name="$1" time_field="$2" fmt="$3" page_size="$4"
  local lo hi
  case "$fmt" in
    rfc3339) lo="$START_UTC"; hi="$END_UTC" ;;
    civil)   lo="$DATE";      hi="$NEXT_DATE" ;;
    *) echo "unknown format $fmt" >&2; return 1 ;;
  esac
  local filter="${time_field} >= \"${lo}\" AND ${time_field} < \"${hi}\""
  local out_file="$OUT_DIR/${url_name}.json"

  echo "Fetching $url_name for $DATE → $out_file"

  local tmpdir
  tmpdir=$(mktemp -d)
  local page=0
  local token=""

  while :; do
    page=$((page + 1))
    local url="${BASE}/${url_name}/dataPoints"
    local args=(
      --get
      --data-urlencode "filter=${filter}"
      --data-urlencode "pageSize=${page_size}"
    )
    [[ -n "$token" ]] && args+=(--data-urlencode "pageToken=${token}")

    local body http_code
    body=$(curl -sS -o "${tmpdir}/page-${page}.json" -w "%{http_code}" \
      -H "Authorization: Bearer ${ACCESS_TOKEN}" \
      "${args[@]}" "$url")
    http_code="$body"

    if [[ "$http_code" != "200" ]]; then
      echo "  ERROR ($http_code) on page $page:" >&2
      cat "${tmpdir}/page-${page}.json" >&2
      echo >&2
      rm -rf "$tmpdir"
      return 1
    fi

    token=$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get("nextPageToken",""))' "${tmpdir}/page-${page}.json")
    [[ -z "$token" ]] && break
  done

  # Merge all pages' dataPoints arrays into one object.
  python3 - "$out_file" "${tmpdir}"/page-*.json <<'PY'
import json, sys, pathlib

out_path = sys.argv[1]
pages = [json.load(open(p)) for p in sys.argv[2:]]
merged = {
    "dataPoints": [dp for page in pages for dp in page.get("dataPoints", [])],
    "pageCount": len(pages),
}
pathlib.Path(out_path).write_text(json.dumps(merged, indent=2) + "\n")
print(f"  {len(merged['dataPoints'])} data points across {len(pages)} page(s)")
PY

  rm -rf "$tmpdir"
}

for entry in "${DATA_TYPES[@]}"; do
  IFS='|' read -r url_name time_field fmt page_size <<<"$entry"
  fetch_type "$url_name" "$time_field" "$fmt" "$page_size"
done

echo
echo "Done. Files written to $OUT_DIR/"
ls -lh "$OUT_DIR/"
