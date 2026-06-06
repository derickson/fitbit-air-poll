#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Token refresh ONLY — no data-lag snapshot side effect.
# refresh-token.sh wraps this and adds the snapshot experiment.

if [[ -f .env ]];   then set -a; source .env;   set +a; fi
if [[ -f .token ]]; then set -a; source .token; set +a; fi

: "${CLIENT_ID:?Missing CLIENT_ID in .env}"
: "${CLIENT_SECRET:?Missing CLIENT_SECRET in .env}"
: "${REFRESH_TOKEN:?Missing REFRESH_TOKEN in .token — run ./auth-url.sh first}"

RESPONSE=$(curl -sS -X POST https://oauth2.googleapis.com/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "refresh_token=$REFRESH_TOKEN" \
  --data-urlencode "grant_type=refresh_token")

python3 - "$RESPONSE" "$REFRESH_TOKEN" <<'PY'
import json, os, sys, time, pathlib

resp = json.loads(sys.argv[1])
current_refresh = sys.argv[2]

if "error" in resp:
    sys.stderr.write(f"[refresh-token] FAILED: {json.dumps(resp)}\n")
    sys.exit(1)

access  = resp["access_token"]
expires = int(time.time()) + int(resp.get("expires_in", 3600))
# Google usually does NOT rotate the refresh token, but honor it if it does.
refresh = resp.get("refresh_token", current_refresh)

lines = [
    f"ACCESS_TOKEN={access}",
    f"REFRESH_TOKEN={refresh}",
    f"ACCESS_TOKEN_EXPIRES_AT={expires}",
]
p = pathlib.Path(".token")
p.write_text("\n".join(lines) + "\n")
os.chmod(p, 0o600)

ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
print(f"[{ts}] refreshed; new access_token expires in {resp.get('expires_in')}s")
PY
