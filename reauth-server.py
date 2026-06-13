#!/usr/bin/env python3
"""Reauthorization UI + backend for the Google Health OAuth token.

The app runs in Google's "Testing" publishing status, so the refresh token
expires ~7 days after each full authorization. This little service lets you
re-authorize from the browser (one click) instead of from the terminal:

  GET /health-reauth/           status page (days left + "Reauthorize" button)
  GET /health-reauth/status     JSON for the page (and for the static dashboard)
  GET /health-reauth/start      302 -> Google consent screen
  GET /health-reauth/callback   Google redirects here with ?code=... ; we
                                exchange it for tokens, write .token, bounce home

It binds to 127.0.0.1 only — nginx reverse-proxies it at
https://lab.azathought.com/health-reauth/ behind the vouch-lab OAuth gate, so
the whole thing is private to the whitelisted Google accounts. The token
exchange (which needs CLIENT_SECRET and writes .token) therefore stays
server-side, which a static page could never do.

Run via the fitbit-reauth.service systemd user unit (see systemd/).
"""

import json
import pathlib
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import token_store

HERE = pathlib.Path(__file__).resolve().parent
ENV_PATH = HERE / ".env"

HOST = "127.0.0.1"
PORT = 8788
BASE = "/health-reauth"

# Must EXACTLY match a redirect URI registered on the OAuth web client in the
# GCP console. (The terminal flow in auth-url.sh uses https://www.google.com.)
REDIRECT_URI = "https://lab.azathought.com/health-reauth/callback"

TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"

SCOPES = [
    "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly",
    "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.writeonly",
    "https://www.googleapis.com/auth/googlehealth.nutrition.readonly",
    "https://www.googleapis.com/auth/googlehealth.nutrition.writeonly",
    "https://www.googleapis.com/auth/googlehealth.sleep.readonly",
]


def load_env() -> dict:
    """Read CLIENT_ID / CLIENT_SECRET from .env (real env vars win)."""
    import os

    env = token_store.read_token(ENV_PATH)  # generic KEY=value parser
    for key in ("CLIENT_ID", "CLIENT_SECRET"):
        if os.environ.get(key):
            env[key] = os.environ[key]
    return env


def status_payload() -> dict:
    """Refresh-token health, derived from .token (see token_store)."""
    tok = token_store.read_token()
    now = int(time.time())

    rt_exp = tok.get("REFRESH_TOKEN_EXPIRES_AT")
    granted = tok.get("AUTH_GRANTED_AT")
    has_token = bool(tok.get("REFRESH_TOKEN"))

    days_left = None
    expired = None
    if rt_exp:
        seconds_left = int(rt_exp) - now
        days_left = round(seconds_left / 86400, 1)
        expired = seconds_left <= 0

    return {
        "has_token": has_token,
        "granted_at": int(granted) if granted else None,
        "expires_at": int(rt_exp) if rt_exp else None,
        "days_left": days_left,
        "expired": expired,
        "tracked": rt_exp is not None,  # False until first reauth via the new flow
        "now": now,
    }


def build_auth_url(env: dict) -> str:
    params = {
        "client_id": env["CLIENT_ID"],
        "redirect_uri": REDIRECT_URI,
        "response_type": "code",
        "access_type": "offline",
        "prompt": "consent",
        "scope": " ".join(SCOPES),
    }
    return AUTH_ENDPOINT + "?" + urllib.parse.urlencode(params)


def exchange_code(env: dict, code: str) -> dict:
    data = urllib.parse.urlencode(
        {
            "code": code,
            "client_id": env["CLIENT_ID"],
            "client_secret": env["CLIENT_SECRET"],
            "redirect_uri": REDIRECT_URI,
            "grant_type": "authorization_code",
        }
    ).encode()
    req = urllib.request.Request(
        TOKEN_ENDPOINT,
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:  # Google returns JSON error bodies
        try:
            return json.loads(exc.read().decode())
        except Exception:
            return {"error": f"http_{exc.code}", "error_description": str(exc)}


PAGE = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Health Reauth</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Crect width='24' height='24' rx='5' fill='%230d2137'/%3E%3Cpath d='M12 2a5 5 0 0 0-5 5v3H6v10h12V10h-1V7a5 5 0 0 0-5-5zm3 8H9V7a3 3 0 0 1 6 0z' fill='%234dd0e1'/%3E%3C/svg%3E">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    background: linear-gradient(135deg, #0a1628 0%, #0d2137 50%, #0a1628 100%);
    color: #fff; min-height: 100vh; padding: 40px 20px;
    display: flex; justify-content: center;
  }
  .card {
    background: rgba(10, 30, 60, 0.85); backdrop-filter: blur(15px);
    border: 1px solid rgba(77, 208, 225, 0.3); border-radius: 12px;
    padding: 32px; max-width: 560px; width: 100%;
  }
  a.back { color: #a0c0d0; font-size: .8rem; letter-spacing: 1px;
    text-decoration: none; }
  a.back:hover { color: #4dd0e1; }
  h1 { font-size: 1.5rem; font-weight: 400; letter-spacing: 1px;
    margin: 14px 0 4px; }
  p.sub { color: #a0c0d0; font-size: .9rem; margin-bottom: 24px; }
  .days { font-size: 3rem; font-weight: 600; line-height: 1; }
  .days small { font-size: 1rem; font-weight: 400; color: #a0c0d0; }
  .ok    { color: #4dd0e1; }
  .warn  { color: #ffb74d; }
  .crit  { color: #ff6b6b; }
  .meta { color: #a0c0d0; font-size: .85rem; margin: 18px 0 28px;
    line-height: 1.7; }
  .meta b { color: #fff; font-weight: 500; }
  .btn {
    display: inline-block; padding: 12px 28px; border-radius: 999px;
    background: rgba(77, 208, 225, 0.18);
    border: 1px solid rgba(77, 208, 225, 0.7); color: #4dd0e1;
    font-size: 1rem; letter-spacing: .5px; text-decoration: none;
    cursor: pointer; transition: all .2s;
  }
  .btn:hover { background: rgba(77, 208, 225, 0.32); }
  .banner { padding: 12px 16px; border-radius: 8px; margin-bottom: 20px;
    font-size: .9rem; }
  .banner.good { background: rgba(77,208,225,.15);
    border: 1px solid rgba(77,208,225,.5); }
  .banner.bad  { background: rgba(255,107,107,.12);
    border: 1px solid rgba(255,107,107,.5); color: #ffb4b4; }
</style>
</head>
<body>
  <div class="card">
    <a class="back" href="https://lab.azathought.com/health/">&larr; Health dashboard</a>
    <h1>Google Health Reauthorization</h1>
    <p class="sub">The app runs in Testing mode, so the refresh token expires
      ~7 days after each authorization. Reauthorize weekly to keep the data
      pipeline alive.</p>
    <div id="banner"></div>
    <div id="status">Loading…</div>
    <p style="margin-top:28px;">
      <a class="btn" href="/health-reauth/start">Reauthorize &rarr;</a>
    </p>
  </div>
<script>
function fmt(ts) {
  if (!ts) return "—";
  return new Date(ts * 1000).toLocaleString();
}
function banner() {
  var p = new URLSearchParams(location.search);
  var el = document.getElementById("banner");
  if (p.get("ok")) {
    el.innerHTML = '<div class="banner good">✅ Reauthorized — the 7-day clock has been reset.</div>';
  } else if (p.get("err")) {
    el.innerHTML = '<div class="banner bad">⚠️ Reauthorization failed: ' +
      p.get("err").replace(/[<>&]/g, "") + '</div>';
  }
}
async function load() {
  banner();
  try {
    var r = await fetch("/health-reauth/status");
    var s = await r.json();
    var cls = "ok", label = "days until reauth needed";
    if (!s.tracked) {
      document.getElementById("status").innerHTML =
        '<div class="days warn">— <small>expiry not yet tracked</small></div>' +
        '<div class="meta">Reauthorize once below to start the countdown.</div>';
      return;
    }
    if (s.expired) { cls = "crit"; label = "EXPIRED — reauthorize now"; }
    else if (s.days_left <= 2) cls = "crit";
    else if (s.days_left <= 4) cls = "warn";
    var n = s.expired ? "⚠" : s.days_left;
    document.getElementById("status").innerHTML =
      '<div class="days ' + cls + '">' + n + ' <small>' + label + '</small></div>' +
      '<div class="meta">' +
        '<div>Last authorized: <b>' + fmt(s.granted_at) + '</b></div>' +
        '<div>Refresh token expires: <b>' + fmt(s.expires_at) + '</b></div>' +
      '</div>';
  } catch (e) {
    document.getElementById("status").innerHTML =
      '<div class="banner bad">Could not load status: ' + e + '</div>';
  }
}
load();
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, content_type="text/html; charset=utf-8", headers=None):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.end_headers()

    def do_GET(self):  # noqa: N802 (http.server API)
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path.rstrip("/") or BASE

        if path == BASE:
            self._send(200, PAGE)
            return

        if path == BASE + "/status":
            self._send(
                200,
                json.dumps(status_payload()),
                content_type="application/json",
                headers={"Cache-Control": "no-store"},
            )
            return

        if path == BASE + "/start":
            env = load_env()
            if not env.get("CLIENT_ID"):
                self._redirect(BASE + "/?err=" + urllib.parse.quote("CLIENT_ID missing in .env"))
                return
            self._redirect(build_auth_url(env))
            return

        if path == BASE + "/callback":
            query = urllib.parse.parse_qs(parsed.query)
            if "error" in query:
                self._redirect(BASE + "/?err=" + urllib.parse.quote(query["error"][0]))
                return
            code = query.get("code", [""])[0]
            if not code:
                self._redirect(BASE + "/?err=" + urllib.parse.quote("no code returned"))
                return

            env = load_env()
            resp = exchange_code(env, code)
            if "error" in resp:
                msg = resp.get("error_description") or resp.get("error")
                self._redirect(BASE + "/?err=" + urllib.parse.quote(str(msg)))
                return

            now = int(time.time())
            fields = token_store.apply_token_response(
                resp, now=now, prior=token_store.read_token(), is_new_grant=True
            )
            token_store.write_token(fields)
            self._redirect(BASE + "/?ok=1")
            return

        self._send(404, "Not found", content_type="text/plain")

    def log_message(self, fmt, *args):  # quieter logs; systemd journal captures these
        import sys

        sys.stderr.write("[reauth] " + (fmt % args) + "\n")


def main():
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"[reauth] listening on http://{HOST}:{PORT}{BASE}/  (proxy at {REDIRECT_URI.rsplit('/', 1)[0]}/)")
    server.serve_forever()


if __name__ == "__main__":
    main()
