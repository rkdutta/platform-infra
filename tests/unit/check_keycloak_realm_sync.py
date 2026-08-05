#!/usr/bin/env python3
"""The Keycloak realm exists as two hand-synced copies (documented gotcha in
platform-infra/CLAUDE.md and platform-idp/CLAUDE.md): the inline realm-import
JSON rendered by apps/security/keycloak/application.yaml (what Argo CD
actually deploys) and platform-idp/teams-management/teams-realm.json (the
local/compose realm). Nothing enforces they match.

They are NOT expected to be identical — the k8s realm has infra-only clients
(argocd, harbor, openbao, teams-cli, teams-operator-kc-admin) that never run
in local compose, and legacy realm roles (`team-leader`, `viewer`) that
teams-api's own code comments say are superseded and no longer read. Full-set
equality would be a false-positive machine.

What actually matters: whichever realm roles teams-api's `auth.py` currently
reads via `_roles(claims)` membership checks must exist in BOTH copies, or a
role gate that works in k8s silently can't be exercised locally at all (this
is how it was found: teams-api/auth.py reads `admin` + `project-manager`, but
the local teams-realm.json was still on the pre-rename `team-leader` +
`admin` role pair — `project-manager` didn't exist locally).
"""
import json
import os
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent.parent
INFRA_APP = ROOT / "apps" / "security" / "keycloak" / "application.yaml"
PLATFORM_IDP = Path(os.environ.get("PLATFORM_IDP", str(ROOT.parent / "platform-idp")))
IDP_REALM = PLATFORM_IDP / "teams-management" / "teams-realm.json"
AUTH_PY = PLATFORM_IDP / "teams-management" / "teams-api" / "auth.py"

ROLE_REF_RE = re.compile(r'"([\w-]+)"\s+(?:not\s+)?in\s+_roles\(claims\)')


def infra_realm():
    app = yaml.safe_load(INFRA_APP.read_text())
    helm_values = yaml.safe_load(app["spec"]["source"]["helm"]["values"])
    for manifest in helm_values["extraManifests"]:
        if manifest.get("kind") == "ConfigMap" and manifest["metadata"]["name"] == "keycloak-realm-import":
            return json.loads(manifest["data"]["teams-realm.json"])
    raise RuntimeError(f"keycloak-realm-import ConfigMap not found in {INFRA_APP}")


def realm_role_names(realm):
    return {r["name"] for r in realm.get("roles", {}).get("realm", [])}


def main():
    if not IDP_REALM.exists() or not AUTH_PY.exists():
        print(f"platform-idp not found as a sibling checkout at {PLATFORM_IDP} — skipping (set PLATFORM_IDP to override)")
        sys.exit(0)

    used_roles = set(ROLE_REF_RE.findall(AUTH_PY.read_text()))
    if not used_roles:
        print(f"no role references found in {AUTH_PY} via {ROLE_REF_RE.pattern} — check the pattern still matches auth.py's style")
        sys.exit(1)

    infra_roles = realm_role_names(infra_realm())
    idp_roles = realm_role_names(json.loads(IDP_REALM.read_text()))

    errors = []
    missing_infra = used_roles - infra_roles
    missing_idp = used_roles - idp_roles
    if missing_infra:
        errors.append(f"roles used by auth.py but missing from the platform-infra (k8s) realm: {sorted(missing_infra)}")
    if missing_idp:
        errors.append(f"roles used by auth.py but missing from the platform-idp (local/compose) realm: {sorted(missing_idp)}")

    if errors:
        print(f"{len(errors)} problem(s):")
        for e in errors:
            print(f"  {e}")
        sys.exit(1)

    print(f"realm roles actually used by auth.py ({sorted(used_roles)}) present in both realm copies")


if __name__ == "__main__":
    main()
