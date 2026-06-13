#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

if [[ -f .env ]]; then
  set -a; source .env; set +a
fi

: "${CLIENT_ID:?Set CLIENT_ID in .env}"
: "${CLIENT_SECRET:?Set CLIENT_SECRET in .env}"

REDIRECT_URI="https://www.google.com"
SCOPES=(
  "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly"
  "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly"
  "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly"
  "https://www.googleapis.com/auth/googlehealth.nutrition.readonly"
  "https://www.googleapis.com/auth/googlehealth.nutrition.writeonly"
  "https://www.googleapis.com/auth/googlehealth.sleep.readonly"
)

urlencode() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }

SCOPE_PARAM=$(urlencode "${SCOPES[*]}")
REDIRECT_ENC=$(urlencode "$REDIRECT_URI")

AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
AUTH_URL+="?client_id=${CLIENT_ID}"
AUTH_URL+="&redirect_uri=${REDIRECT_ENC}"
AUTH_URL+="&response_type=code"
AUTH_URL+="&access_type=offline"
AUTH_URL+="&prompt=consent"
AUTH_URL+="&scope=${SCOPE_PARAM}"

echo
echo "Opening Google OAuth consent in your browser…"
echo "If it doesn't open, visit this URL manually:"
echo
echo "  $AUTH_URL"
echo

if command -v open >/dev/null 2>&1; then
  open "$AUTH_URL" || true
fi

echo "After approving, you'll be redirected to a https://www.google.com/?code=… URL."
echo "Paste that full URL (or just the code) here and press Enter:"
echo
read -r PASTED

# Extract code= value whether they pasted full URL or bare code.
CODE=$(python3 - "$PASTED" <<'PY'
import sys, urllib.parse
s = sys.argv[1].strip()
if s.startswith("http"):
    q = urllib.parse.urlparse(s).query
    code = urllib.parse.parse_qs(q).get("code", [""])[0]
else:
    code = s.split("&")[0].replace("code=", "")
if not code:
    sys.exit("Could not find a code in the pasted value.")
print(code)
PY
)

echo
echo "Exchanging code for tokens…"

RESPONSE=$(curl -sS -X POST https://oauth2.googleapis.com/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "grant_type=authorization_code")

# Parse + persist with python (no jq dependency).
python3 - "$RESPONSE" <<'PY'
import json, sys, time
import token_store

resp = json.loads(sys.argv[1])
if "error" in resp:
    sys.exit(f"Token exchange failed: {json.dumps(resp, indent=2)}")

now = int(time.time())
# is_new_grant=True: a full authorization resets the 7-day clock and stamps
# AUTH_GRANTED_AT / REFRESH_TOKEN_EXPIRES_AT (from refresh_token_expires_in).
fields = token_store.apply_token_response(
    resp, now=now, prior=token_store.read_token(), is_new_grant=True
)
token_store.write_token(fields)

rt_exp = resp.get("refresh_token_expires_in")  # present in Testing mode (~7d)
print("Saved tokens to .token (chmod 600).")
print(f"  access_token expires in {resp.get('expires_in')}s")
if fields.get("REFRESH_TOKEN"):
    if rt_exp is None:
        print("  refresh_token: (persistent — app appears to be In production)")
    else:
        days = int(rt_exp) / 86400
        print(f"  refresh_token expires in {rt_exp}s (~{days:.1f}d) — app is in Testing mode")
else:
    print("  no refresh_token returned (re-run with prompt=consent if you need one)")
PY

echo
exec ./validate-token.sh
