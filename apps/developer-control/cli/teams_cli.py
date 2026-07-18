#!/usr/bin/env python3
"""
Teams CLI - A simple command-line interface for the Teams API
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import secrets
import sys
import time
import urllib.parse
import webbrowser
from pathlib import Path
from typing import Optional

import requests
import urllib3

# Default API base URL, overridable (in precedence order) by the --url flag or
# the TEAMS_API_URL environment variable.
ENV_URL_VAR = "TEAMS_API_URL"
DEFAULT_API_BASE_URL = "http://teams-api.127.0.0.1.sslip.io"
API_BASE_URL = os.environ.get(ENV_URL_VAR, DEFAULT_API_BASE_URL)

# --- Keycloak / OIDC login config (Authorization Code + PKCE, loopback) -------
# All overridable by environment so the same CLI works against other realms.
AUTH_URL = os.environ.get("TEAMS_AUTH_URL", "https://platform-auth.127.0.0.1.sslip.io:8443/auth")
AUTH_REALM = os.environ.get("TEAMS_AUTH_REALM", "teams")
AUTH_CLIENT = os.environ.get("TEAMS_AUTH_CLIENT", "teams-cli")
# The loopback redirect must match one registered on the teams-cli client.
REDIRECT_PORT = int(os.environ.get("TEAMS_AUTH_REDIRECT_PORT", "8400"))
REDIRECT_URI = f"http://localhost:{REDIRECT_PORT}/callback"

# Stored token location (0600). Honors XDG_CONFIG_HOME.
TOKEN_DIR = Path(os.environ.get("XDG_CONFIG_HOME", str(Path.home() / ".config"))) / "teams-cli"
TOKEN_FILE = TOKEN_DIR / "tokens.json"


def _oidc(auth_url: str, realm: str, endpoint: str) -> str:
    return f"{auth_url}/realms/{realm}/protocol/openid-connect/{endpoint}"


def _b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode()


def _pkce_pair() -> tuple[str, str]:
    """Return (code_verifier, code_challenge) for PKCE S256."""
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def _decode_jwt_claims(token: str) -> dict:
    """Decode a JWT payload WITHOUT verifying the signature (display only —
    the API is responsible for real verification)."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # pad base64url
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    """Catches the single browser redirect to /callback and stashes its query."""

    result: dict = {}

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        if parsed.path != "/callback":
            self.send_response(404)
            self.end_headers()
            return
        _CallbackHandler.result = {k: v[0] for k, v in urllib.parse.parse_qs(parsed.query).items()}
        ok = "code" in _CallbackHandler.result
        msg = ("Login successful — you can close this tab and return to the terminal."
               if ok else "Login failed — see the terminal.")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(
            f"<html><body style='font-family:sans-serif;text-align:center;margin-top:3rem'>"
            f"<h3>{msg}</h3></body></html>".encode()
        )

    def log_message(self, *args):  # silence the default stderr logging
        pass

class TeamsAPI:
    def __init__(self, base_url: str = API_BASE_URL, verify: bool = True):
        self.base_url = base_url
        self.verify = verify
        if not verify:
            # Self-signed certificates: skip verification and silence the
            # per-request InsecureRequestWarning so output stays readable.
            urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    def _make_request(self, method: str, endpoint: str, data: Optional[dict] = None) -> dict:
        """Make HTTP request to the API"""
        url = f"{self.base_url}{endpoint}"
        # Attach the bearer token if the user has logged in (see `login`).
        headers = {"Content-Type": "application/json"}
        token = self._access_token()
        if token:
            headers["Authorization"] = f"Bearer {token}"
        try:
            if method == "GET":
                response = requests.get(url, headers=headers, verify=self.verify)
            elif method == "POST":
                response = requests.post(url, json=data, headers=headers, verify=self.verify)
            elif method == "DELETE":
                response = requests.delete(url, headers=headers, verify=self.verify)
            else:
                raise ValueError(f"Unsupported method: {method}")
                
            response.raise_for_status()
            return response.json()
        except requests.exceptions.SSLError as e:
            print(f"❌ TLS Error: certificate verification failed for {self.base_url}")
            print("   If this is a self-signed certificate, re-run with --insecure (-k).")
            print(f"   ({e})")
            sys.exit(1)
        except requests.exceptions.ConnectionError:
            print(f"❌ Error: Could not connect to API at {self.base_url}")
            print("   Make sure the Teams API is running")
            sys.exit(1)
        except requests.exceptions.HTTPError as e:
            if response.status_code == 400:
                error_detail = response.json().get("detail", "Bad request")
                print(f"❌ Error: {error_detail}")
            elif response.status_code in (401, 403):
                print(f"❌ Not authorized ({response.status_code}). Your session may be "
                      "missing or expired — run `teams-cli login`.")
            elif response.status_code == 404:
                print("❌ Error: Team not found")
            else:
                print(f"❌ HTTP Error {response.status_code}: {e}")
            sys.exit(1)
        except Exception as e:
            print(f"❌ Unexpected error: {e}")
            sys.exit(1)

    def health_check(self):
        """Check API health"""
        result = self._make_request("GET", "/health")
        status = result.get("status", "unknown")
        teams_count = result.get("teams_count", 0)
        print(f"✅ API Status: {status}")
        print(f"📊 Teams Count: {teams_count}")

    def create_team(self, name: str):
        """Create a new team"""
        result = self._make_request("POST", "/teams", {"name": name})
        print(f"✅ Created team: {result['name']}")
        print(f"🆔 Team ID: {result['id']}")
        print(f"📅 Created: {result['created_at']}")

    def list_teams(self):
        """List all teams"""
        teams = self._make_request("GET", "/teams")
        if not teams:
            print("📭 No teams found")
            return
            
        print(f"📋 Found {len(teams)} team(s):")
        print("-" * 60)
        for team in teams:
            print(f"🏷️  Name: {team['name']}")
            print(f"🆔 ID: {team['id']}")
            print(f"📅 Created: {team['created_at']}")
            print("-" * 60)

    def get_team(self, team_id: str):
        """Get a specific team by ID"""
        team = self._make_request("GET", f"/teams/{team_id}")
        print(f"🏷️  Name: {team['name']}")
        print(f"🆔 ID: {team['id']}")
        print(f"📅 Created: {team['created_at']}")

    def delete_team(self, team_id: str):
        """Delete a team"""
        result = self._make_request("DELETE", f"/teams/{team_id}")
        print(f"✅ {result['message']}")

    # --- Authentication (OAuth2 Authorization Code + PKCE, loopback) ----------

    def _save_tokens(self, tok: dict):
        """Persist tokens (0600) plus the auth context needed to refresh."""
        TOKEN_DIR.mkdir(parents=True, exist_ok=True)
        data = {
            "access_token": tok["access_token"],
            "refresh_token": tok.get("refresh_token"),
            "id_token": tok.get("id_token"),
            "expires_at": time.time() + int(tok.get("expires_in", 0)),
            "auth_url": AUTH_URL,
            "realm": AUTH_REALM,
            "client": AUTH_CLIENT,
        }
        TOKEN_FILE.write_text(json.dumps(data))
        os.chmod(TOKEN_FILE, 0o600)

    def _access_token(self) -> Optional[str]:
        """Return a usable access token: from disk, refreshing if it's expired.
        Returns None when the user hasn't logged in."""
        if not TOKEN_FILE.exists():
            return None
        data = json.loads(TOKEN_FILE.read_text())
        if time.time() < data.get("expires_at", 0) - 30:
            return data["access_token"]
        # Expired (or nearly): try a refresh_token grant.
        if data.get("refresh_token"):
            try:
                resp = requests.post(
                    _oidc(data["auth_url"], data["realm"], "token"),
                    data={"grant_type": "refresh_token", "client_id": data["client"],
                          "refresh_token": data["refresh_token"]},
                    verify=self.verify, timeout=15,
                )
                if resp.status_code == 200:
                    self._save_tokens(resp.json())
                    return json.loads(TOKEN_FILE.read_text())["access_token"]
            except requests.exceptions.RequestException:
                pass
        return data.get("access_token")  # possibly stale; the API will 401

    def login(self, no_browser: bool = False):
        """Browser login via Authorization Code + PKCE (S256) with a loopback
        redirect. Opens the Keycloak login page, catches the redirect locally,
        exchanges the code for tokens, and stores them."""
        verifier, challenge = _pkce_pair()
        state = _b64url(secrets.token_bytes(16))
        params = urllib.parse.urlencode({
            "client_id": AUTH_CLIENT,
            "response_type": "code",
            "scope": "openid profile email",
            "redirect_uri": REDIRECT_URI,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
        })
        auth_url = f"{_oidc(AUTH_URL, AUTH_REALM, 'auth')}?{params}"

        try:
            server = http.server.HTTPServer(("127.0.0.1", REDIRECT_PORT), _CallbackHandler)
        except OSError as e:
            print(f"❌ Could not bind {REDIRECT_URI} ({e}).")
            print(f"   Is another login in progress, or is port {REDIRECT_PORT} in use?")
            sys.exit(1)
        server.timeout = 180
        _CallbackHandler.result = {}

        print(f"🔐 Logging in to realm '{AUTH_REALM}' as client '{AUTH_CLIENT}'...")
        opened = (not no_browser) and webbrowser.open(auth_url)
        if opened:
            print(f"   Browser opened. If it didn't, visit:\n   {auth_url}")
        else:
            print(f"   Open this URL in your browser to log in:\n   {auth_url}")
        print(f"   Waiting for the redirect on {REDIRECT_URI} ...")

        start = time.time()
        while not _CallbackHandler.result and time.time() - start < server.timeout:
            server.handle_request()
        server.server_close()

        res = _CallbackHandler.result
        if not res:
            print("❌ Timed out waiting for the browser login.")
            sys.exit(1)
        if res.get("state") != state:
            print("❌ State mismatch — aborting (possible CSRF).")
            sys.exit(1)
        if "code" not in res:
            print(f"❌ Login failed: {res.get('error_description', res.get('error', 'no code returned'))}")
            sys.exit(1)

        try:
            resp = requests.post(
                _oidc(AUTH_URL, AUTH_REALM, "token"),
                data={"grant_type": "authorization_code", "client_id": AUTH_CLIENT,
                      "code": res["code"], "redirect_uri": REDIRECT_URI,
                      "code_verifier": verifier},
                verify=self.verify, timeout=15,
            )
        except requests.exceptions.SSLError:
            print("❌ TLS error reaching Keycloak. For a self-signed cert, re-run with --insecure (-k).")
            sys.exit(1)
        if resp.status_code != 200:
            print(f"❌ Token exchange failed: {resp.status_code} {resp.text}")
            sys.exit(1)

        self._save_tokens(resp.json())
        claims = _decode_jwt_claims(resp.json()["access_token"])
        print(f"✅ Logged in as {claims.get('preferred_username', '?')}")
        print(f"   roles: {claims.get('realm_access', {}).get('roles', [])}")
        print(f"   token stored at {TOKEN_FILE}")

    def logout(self):
        """Remove the stored token."""
        if TOKEN_FILE.exists():
            TOKEN_FILE.unlink()
            print("👋 Logged out (stored token removed).")
        else:
            print("Not logged in — nothing to remove.")

    def whoami(self):
        """Show the logged-in user and token status from the stored token."""
        if not TOKEN_FILE.exists():
            print("Not logged in. Run: teams-cli login")
            return
        data = json.loads(TOKEN_FILE.read_text())
        claims = _decode_jwt_claims(data["access_token"])
        remaining = int(data.get("expires_at", 0) - time.time())
        print(f"👤 user:  {claims.get('preferred_username', '?')}")
        print(f"📧 email: {claims.get('email', '-')}")
        print(f"🎭 roles: {claims.get('realm_access', {}).get('roles', [])}")
        print(f"🏰 realm: {data.get('realm')}  (client: {data.get('client')})")
        if remaining > 0:
            print(f"⏱️  access token valid for ~{remaining}s")
        else:
            print("⏱️  access token expired (auto-refreshes on next API call)")


def main():
    parser = argparse.ArgumentParser(
        description="Teams CLI - Manage teams via the Teams API",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  teams-cli health                    # Check API health
  teams-cli create "Backend Team"     # Create a new team
  teams-cli list                      # List all teams
  teams-cli get <team-id>            # Get specific team
  teams-cli delete <team-id>         # Delete a team
        """
    )
    
    parser.add_argument(
        "--url",
        default=API_BASE_URL,
        help=f"API base URL. Overrides the {ENV_URL_VAR} env var. "
             f"(env {ENV_URL_VAR} or default: {DEFAULT_API_BASE_URL})"
    )

    parser.add_argument(
        "--insecure", "-k",
        action="store_true",
        help="Skip TLS certificate verification (use for self-signed certs)"
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # Auth commands
    login_parser = subparsers.add_parser(
        "login", help="Log in via browser (OAuth2 Authorization Code + PKCE)")
    login_parser.add_argument(
        "--no-browser", action="store_true",
        help="Print the login URL instead of opening a browser")
    subparsers.add_parser("logout", help="Remove the stored token")
    subparsers.add_parser("whoami", help="Show the logged-in user and token status")

    # Health command
    subparsers.add_parser("health", help="Check API health")
    
    # Create command
    create_parser = subparsers.add_parser("create", help="Create a new team")
    create_parser.add_argument("name", help="Team name")
    
    # List command
    subparsers.add_parser("list", help="List all teams")
    
    # Get command
    get_parser = subparsers.add_parser("get", help="Get a specific team")
    get_parser.add_argument("team_id", help="Team ID")
    
    # Delete command
    delete_parser = subparsers.add_parser("delete", help="Delete a team")
    delete_parser.add_argument("team_id", help="Team ID")
    
    args = parser.parse_args()
    
    if not args.command:
        parser.print_help()
        return
    
    # Initialize API client
    api = TeamsAPI(args.url, verify=not args.insecure)
    
    # Execute command
    try:
        if args.command == "login":
            api.login(no_browser=args.no_browser)
        elif args.command == "logout":
            api.logout()
        elif args.command == "whoami":
            api.whoami()
        elif args.command == "health":
            api.health_check()
        elif args.command == "create":
            api.create_team(args.name)
        elif args.command == "list":
            api.list_teams()
        elif args.command == "get":
            api.get_team(args.team_id)
        elif args.command == "delete":
            api.delete_team(args.team_id)
    except KeyboardInterrupt:
        print("\n👋 Goodbye!")
        sys.exit(0)

if __name__ == "__main__":
    main()
