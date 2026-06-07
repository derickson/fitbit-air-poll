#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Cron entry point: refresh the access token, then fetch the latest data
# and push it to Elasticsearch. Use refresh-token-only.sh for just the
# token refresh.
./refresh-token-only.sh

# Elasticsearch ingest: fetch a fresh two-day window (yesterday + today)
# into a temp dir and push it to Elasticsearch (idempotent; see
# design/ELASTICSEARCH-DESIGN.md). A fetch/ingest failure must not mask the
# successful token refresh.
#
# The data-lag snapshot experiment (./snapshot-health-data.sh accumulating
# runs under data-experiment/) is disabled — run it manually if needed.
(
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  for OFFSET in 1 0; do
    DATE=$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=$OFFSET)).isoformat())")
    OUT_BASE="$TMP_DIR" ./fetch-health-data.sh "$DATE"
  done
  ./ingest-to-elasticsearch.py --run "$TMP_DIR"
) || echo "[fitbit-poll] elasticsearch ingest failed (exit $?)" >&2
