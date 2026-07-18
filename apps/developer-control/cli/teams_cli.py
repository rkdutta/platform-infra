#!/usr/bin/env python3
"""
Teams CLI - A simple command-line interface for the Teams API
"""

import argparse
import json
import os
import sys
import requests
import urllib3
from typing import Optional

# Default API base URL, overridable (in precedence order) by the --url flag or
# the TEAMS_API_URL environment variable.
ENV_URL_VAR = "TEAMS_API_URL"
DEFAULT_API_BASE_URL = "http://teams-api.127.0.0.1.sslip.io"
API_BASE_URL = os.environ.get(ENV_URL_VAR, DEFAULT_API_BASE_URL)

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
        try:
            if method == "GET":
                response = requests.get(url, verify=self.verify)
            elif method == "POST":
                response = requests.post(url, json=data, headers={"Content-Type": "application/json"}, verify=self.verify)
            elif method == "DELETE":
                response = requests.delete(url, verify=self.verify)
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
        if args.command == "health":
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
