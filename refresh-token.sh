#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Cron entry point: refresh the access token, then run the data-lag
# snapshot experiment. Use refresh-token-only.sh for just the refresh.
./refresh-token-only.sh

# Data-lag experiment: snapshot the past two days after every successful
# refresh. A snapshot failure must not mask the successful token refresh.
./snapshot-health-data.sh || echo "[refresh-token] snapshot-health-data.sh failed (exit $?)" >&2
