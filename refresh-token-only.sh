#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

# Token refresh ONLY — no data-fetch side effects.
# fitbit-poll.sh wraps this and adds the Elasticsearch ingest.

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

python3 - "$RESPONSE" <<'PY'
import json, sys, time
import token_store

resp = json.loads(sys.argv[1])

if "error" in resp:
    sys.stderr.write(f"[refresh-token] FAILED: {json.dumps(resp)}\n")
    sys.exit(1)

now = int(time.time())
# is_new_grant=False: a refresh must PRESERVE REFRESH_TOKEN_EXPIRES_AT /
# AUTH_GRANTED_AT — only a full reauthorization resets the 7-day clock.
fields = token_store.apply_token_response(
    resp, now=now, prior=token_store.read_token(), is_new_grant=False
)
token_store.write_token(fields)

ts = time.strftime("%Y-%m-%dT%H:%M:%S%z")
rt_exp = fields.get("REFRESH_TOKEN_EXPIRES_AT")
days_left = (int(rt_exp) - now) / 86400 if rt_exp else None
tail = f"; refresh token expires in {days_left:.1f}d" if days_left is not None else ""
print(f"[{ts}] refreshed; new access_token expires in {resp.get('expires_in')}s{tail}")
PY
