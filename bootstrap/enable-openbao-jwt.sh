#!/usr/bin/env bash
# Bootstrap (and refresh) OpenBao's SPIRE/SPIFFE workload-identity auth: the
# `jwt` auth method that trusts SPIRE's OIDC discovery provider, plus the
# teams-operator's own bootstrap policy+role. Replays steps 2-3 of the
# "OpenBao — one-time init" section of bootstrap/README.md; keep both in sync.
#
# Also the intended fix for the recurring caveat the README calls out: SPIRE's
# root rotates ~daily, so auth/jwt/config's oidc_discovery_ca_pem goes stale and
# workload JWT logins start failing with a TLS trust error. Re-running this
# re-extracts the current SPIRE bundle CA and rewrites the config (safe to
# re-run anytime — the auth-method enable is guarded, everything else is a
# natural overwrite).
#
# Prereqs: OpenBao initialised/unsealed (bootstrap/init-keys.json present),
# SPIRE server + oidc-discovery-provider running, spire-bundle ConfigMap present.
#
# Usage: bootstrap/enable-openbao-jwt.sh
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SPIRE_DISCOVERY_URL="https://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local"
OPERATOR_SPIFFE_ID="spiffe://platform.local/ns/engineering-platform/sa/teams-operator"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

for bin in kubectl jq python3; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required on PATH"
done

[[ -f bootstrap/init-keys.json ]] \
  || die "bootstrap/init-keys.json not found — run the OpenBao init steps in README.md first"
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)
[[ -n "$BAO_TOKEN" && "$BAO_TOKEN" != "null" ]] \
  || die "could not read .root_token from bootstrap/init-keys.json"

bao() { kubectl -n openbao exec -i openbao-0 -- sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN $*"; }

# --- 1. Extract the SPIRE trust-bundle CA (x509-svid entries) as PEM ----------
# spire-bundle holds a SPIFFE JWKS bundle (JSON), not a ready PEM — OpenBao needs
# the CA that signs the discovery provider's TLS SVID to validate the HTTPS pull.
log "extracting SPIRE trust bundle CA from spire-bundle ConfigMap"
tmp_bundle=$(mktemp)
trap 'rm -f "$tmp_bundle"' EXIT
kubectl get cm spire-bundle -n spire-server -o jsonpath='{.data.bundle\.spiffe}' > "$tmp_bundle"
[[ -s "$tmp_bundle" ]] || die "spire-bundle ConfigMap has no bundle.spiffe key"
# argv (not stdin): the heredoc below is python's program source, so stdin is taken.
pem=$(python3 - "$tmp_bundle" <<'PYEOF'
import json, sys, textwrap
with open(sys.argv[1]) as f:
    bundle = json.load(f)
out = []
for key in bundle.get("keys", []):
    if key.get("use") == "x509-svid":
        for der_b64 in key.get("x5c", []):
            out.append("-----BEGIN CERTIFICATE-----")
            out.append("\n".join(textwrap.wrap(der_b64, 64)))
            out.append("-----END CERTIFICATE-----")
sys.stdout.write("\n".join(out) + "\n")
PYEOF
)
[[ "$pem" == *"BEGIN CERTIFICATE"* ]] || die "no x509-svid certs found in spire-bundle"
printf '%s' "$pem" | kubectl -n openbao exec -i openbao-0 -- sh -c 'cat > /tmp/spire-bundle.pem'

# --- 2. Enable the jwt auth method (guarded — errors on a second enable) -------
if bao 'bao auth list -format=json' | jq -e '."jwt/"' >/dev/null 2>&1; then
  log "jwt auth method already enabled, skipping enable"
else
  log "enabling jwt auth method"
  bao 'bao auth enable jwt'
fi

log "writing auth/jwt/config (SPIRE discovery URL + current bundle CA)"
bao "bao write auth/jwt/config \
     oidc_discovery_url=$SPIRE_DISCOVERY_URL \
     oidc_discovery_ca_pem=@/tmp/spire-bundle.pem"
bao 'rm -f /tmp/spire-bundle.pem' || true

# --- 3. teams-operator bootstrap policy + role --------------------------------
# Chicken-and-egg: the operator creates every project-<ns> policy/role itself
# (ensure_openbao_access) once running, but needs its OWN role first. Paths are
# "project-*" to match teams-api's namespace prefix — if that prefix changes,
# this must change with it or every namespace's OpenBao write starts 403ing.
log "writing teams-operator-admin-policy"
bao 'bao policy write teams-operator-admin-policy -' <<'EOF'
path "sys/policies/acl/project-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/jwt/role/project-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "identity/group/name/project-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "identity/group-alias" {
  capabilities = ["create", "update"]
}
path "sys/auth" {
  capabilities = ["read"]
}
path "kv/metadata/projects/*" {
  capabilities = ["read", "list", "delete"]
}
EOF

# platform-operator-policy: the operator's READ access to the platform-management
# layer (kv/platform/*), notably kv/platform/github-app/ where the GitHub App
# private key lives (see docs/self-service-repos-github-app.md). Created here by
# root, NOT rendered by the operator — its name is outside the operator's own
# "project-*" self-management glob on purpose, so the operator can never widen
# its own platform access.
log "writing platform-operator-policy (operator read of kv/platform/*)"
bao 'bao policy write platform-operator-policy -' <<'EOF'
path "kv/data/platform/*" {
  capabilities = ["read", "list"]
}
path "kv/metadata/platform/*" {
  capabilities = ["read", "list"]
}
# Per-project GitHub App "connections" (the self-service multi-connection flow,
# see docs/self-service-repos-github-app.md): the operator CREATES these entries,
# writing each newly-registered App's private key after converting the GitHub
# App-Manifest code (resolve_github_registrations / _store_connection_app_key).
# A more-specific path wins over the read-only kv/data/platform/* glob above, so
# write is scoped to exactly the github-apps subtree — not all of platform/*.
path "kv/data/platform/github-apps/*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "kv/metadata/platform/github-apps/*" {
  capabilities = ["read", "list", "delete"]
}
EOF

log "writing auth/jwt/role/teams-operator-admin"
bao 'bao write auth/jwt/role/teams-operator-admin -' <<EOF
{
  "role_type": "jwt",
  "bound_audiences": ["openbao"],
  "user_claim": "sub",
  "bound_claims_type": "glob",
  "bound_claims": {
    "sub": "$OPERATOR_SPIFFE_ID"
  },
  "token_policies": ["teams-operator-admin-policy", "platform-operator-policy"],
  "token_ttl": "15m",
  "token_max_ttl": "1h"
}
EOF

log "OpenBao SPIRE/SPIFFE jwt auth ready — teams-operator can now provision per-project OpenBao access"
