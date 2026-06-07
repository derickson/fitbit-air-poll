#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Data-lag experiment: snapshot the past two civil days (yesterday + today)
# into data-experiment/<run-start-timestamp>/, one subfolder per run.
# Repeated runs (manual — no longer part of the fitbit-poll.sh cron cycle)
# can later be diffed to detect late-arriving or revised data — the
# device→phone→Google Health sync chain means a pull may see incomplete
# data that is overwritten later.

read -r RUN_EPOCH RUN_TS RUN_ISO <<<"$(python3 -c "
import time
now = int(time.time())
print(now,
      time.strftime('%Y-%m-%dT%H-%M-%SZ', time.gmtime(now)),
      time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now)))
")"

SNAP_DIR="data-experiment/$RUN_TS"
mkdir -p "$SNAP_DIR"

printf '{"run_started_utc": "%s", "run_started_epoch": %s}\n' \
  "$RUN_ISO" "$RUN_EPOCH" > "$SNAP_DIR/meta.json"

echo "[snapshot] run $RUN_TS → $SNAP_DIR/"

# Yesterday first, then today (local civil days, matching fetch-health-data.sh).
for OFFSET in 1 0; do
  DATE=$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=$OFFSET)).isoformat())")
  OUT_BASE="$SNAP_DIR" ./fetch-health-data.sh "$DATE"
done

echo "[snapshot] run $RUN_TS complete"
