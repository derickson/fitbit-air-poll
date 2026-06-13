"""Shared .token read/write for the Google Health OAuth flow.

`.token` holds shell-sourceable KEY=value lines (so the bash scripts can
`set -a; source .token`):

  ACCESS_TOKEN              the current bearer token
  REFRESH_TOKEN            used to mint new access tokens
  ACCESS_TOKEN_EXPIRES_AT   unix seconds; access tokens live ~1h
  REFRESH_TOKEN_EXPIRES_AT  unix seconds; in Testing mode Google expires the
                            refresh token ~7 days after a full authorization
  AUTH_GRANTED_AT           unix seconds of the last full authorization_code grant

The 30-min refresh (refresh-token-only.sh) rewrites .token but must PRESERVE
REFRESH_TOKEN_EXPIRES_AT / AUTH_GRANTED_AT — only a full reauthorization
(auth-url.sh or the reauth server's /callback) resets that 7-day clock.
"""

import os
import pathlib

TOKEN_PATH = pathlib.Path(__file__).resolve().parent / ".token"

# Google's documented refresh-token lifetime for apps in "Testing" publishing
# status. Used as a fallback when a token response omits refresh_token_expires_in
# (the refresh_token grant typically does not return it).
TESTING_REFRESH_TTL = 7 * 24 * 3600

# Stable field order so the file stays diff-friendly across rewrites.
_FIELD_ORDER = [
    "ACCESS_TOKEN",
    "REFRESH_TOKEN",
    "ACCESS_TOKEN_EXPIRES_AT",
    "REFRESH_TOKEN_EXPIRES_AT",
    "AUTH_GRANTED_AT",
]


def read_token(path=TOKEN_PATH) -> dict:
    """Parse .token into a dict. Returns {} if the file does not exist."""
    data: dict = {}
    p = pathlib.Path(path)
    if not p.exists():
        return data
    for line in p.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        data[key.strip()] = value.strip()
    return data


def write_token(fields: dict, path=TOKEN_PATH) -> None:
    """Write the known fields to .token (chmod 600), in stable order."""
    lines = [f"{k}={fields[k]}" for k in _FIELD_ORDER if fields.get(k) not in (None, "")]
    p = pathlib.Path(path)
    p.write_text("\n".join(lines) + "\n")
    os.chmod(p, 0o600)


def apply_token_response(resp: dict, *, now: int, prior: dict, is_new_grant: bool) -> dict:
    """Merge a Google token response into the fields to persist.

    is_new_grant=True  -> authorization_code exchange: resets the 7-day clock
                          and stamps AUTH_GRANTED_AT.
    is_new_grant=False -> refresh_token grant: carries the prior expiry /
                          granted-at forward (Google usually omits them here),
                          but honors a fresh refresh_token_expires_in if sent.
    """
    out = dict(prior)  # carry forward REFRESH_TOKEN_EXPIRES_AT / AUTH_GRANTED_AT
    out["ACCESS_TOKEN"] = resp["access_token"]
    out["ACCESS_TOKEN_EXPIRES_AT"] = str(now + int(resp.get("expires_in", 3600)))

    # Google usually does NOT rotate the refresh token, but honor it if it does.
    refresh = resp.get("refresh_token") or prior.get("REFRESH_TOKEN")
    if refresh:
        out["REFRESH_TOKEN"] = refresh

    rt_exp = resp.get("refresh_token_expires_in")
    if is_new_grant:
        out["AUTH_GRANTED_AT"] = str(now)
        ttl = int(rt_exp) if rt_exp is not None else TESTING_REFRESH_TTL
        out["REFRESH_TOKEN_EXPIRES_AT"] = str(now + ttl)
    elif rt_exp is not None:
        out["REFRESH_TOKEN_EXPIRES_AT"] = str(now + int(rt_exp))

    return out
