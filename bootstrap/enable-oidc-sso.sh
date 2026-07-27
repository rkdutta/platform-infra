#!/usr/bin/env bash
# One-time setup: OpenBao + Harbor OIDC login via Keycloak's "teams" realm.
#
# Companion script to the "OpenBao — enable OIDC login via Keycloak" and
# "Harbor — enable OIDC login via Keycloak" sections of bootstrap/README.md —
# this just runs those documented commands; keep both in sync if either
# changes (client secrets, redirect URIs, issuer URL, group names).
#
# Prereqs:
#   - apps/security/keycloak/application.yaml (openbao/harbor Keycloak
#     clients) and apps/integration-delivery/harbor/application.yaml
#     (caBundleSecretName) already pushed and synced by Argo CD.
#   - bootstrap/init-keys.json present (OpenBao root token — see the
#     "OpenBao — one-time init" section of the README).
#   - platform-tls already created in both the openbao and harbor namespaces
#     (see the "platform-tls" section of the README).
#
# Safe to re-run: each step either checks first or is a natural overwrite
# (bao write / Harbor's PUT config), except "bao auth enable oidc", which is
# explicitly guarded below since OpenBao errors on a second enable.
#
# Usage: bootstrap/enable-oidc-sso.sh [openbao|harbor|all]  (default: all)

set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KEYCLOAK_ISSUER="https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams"
HARBOR_URL="https://harbor.127.0.0.1.sslip.io:8443"
HARBOR_ADMIN_USER="admin"
HARBOR_ADMIN_PASS="Harbor12345" # DEMO credential, matches the rest of this repo

log()  { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

for bin in kubectl jq curl base64; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required on PATH"
done

# ---------------------------------------------------------------------------
# OpenBao
# ---------------------------------------------------------------------------
enable_openbao_oidc() {
  [[ -f bootstrap/init-keys.json ]] \
    || die "bootstrap/init-keys.json not found — run the OpenBao init steps in README.md first"
  local bao_token
  bao_token=$(jq -r '.root_token' bootstrap/init-keys.json)
  [[ -n "$bao_token" && "$bao_token" != "null" ]] \
    || die "could not read .root_token from bootstrap/init-keys.json"

  log "OpenBao: checking oidc auth method"
  if kubectl -n openbao exec openbao-0 -- sh -c \
      "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$bao_token bao auth list -format=json" \
      | jq -e '."oidc/"' >/dev/null 2>&1; then
    log "OpenBao: oidc auth method already enabled, skipping enable"
  else
    log "OpenBao: enabling oidc auth method"
    kubectl -n openbao exec openbao-0 -- sh -c \
      "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$bao_token bao auth enable oidc"
  fi

  log "OpenBao: fetching platform-tls cert (openbao namespace) for oidc_discovery_ca_pem"
  local tmp_cert
  tmp_cert=$(mktemp)
  kubectl get secret platform-tls -n openbao -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp_cert"
  if [[ ! -s "$tmp_cert" ]]; then
    rm -f "$tmp_cert"
    die "platform-tls secret in openbao namespace has no tls.crt — see README's platform-tls section"
  fi
  kubectl -n openbao cp "$tmp_cert" openbao-0:/tmp/platform-tls.crt
  rm -f "$tmp_cert"

  log "OpenBao: writing auth/oidc/config"
  kubectl -n openbao exec openbao-0 -- sh -c \
    "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$bao_token bao write auth/oidc/config \
       oidc_discovery_url=$KEYCLOAK_ISSUER \
       oidc_client_id=openbao \
       oidc_client_secret=dev-openbao-oidc-secret-change-me \
       default_role=default \
       oidc_discovery_ca_pem=@/tmp/platform-tls.crt"
  kubectl -n openbao exec openbao-0 -- rm -f /tmp/platform-tls.crt

  log "OpenBao: writing auth/oidc/role/default"
  kubectl -n openbao exec -i openbao-0 -- sh -c \
    "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$bao_token bao write auth/oidc/role/default -" <<'EOF'
{
  "role_type": "oidc",
  "bound_audiences": ["openbao"],
  "allowed_redirect_uris": [
    "https://openbao.127.0.0.1.sslip.io:8443/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "policies": ["default"],
  "ttl": "1h"
}
EOF

  log "OpenBao OIDC login ready — https://openbao.127.0.0.1.sslip.io:8443/ui/ (OIDC button) or 'bao login -method=oidc'"
}

# ---------------------------------------------------------------------------
# Harbor
# ---------------------------------------------------------------------------
enable_harbor_oidc() {
  log "Harbor: checking harbor-ca-bundle secret"
  if kubectl get secret harbor-ca-bundle -n harbor >/dev/null 2>&1; then
    log "Harbor: harbor-ca-bundle already exists, skipping create"
  else
    log "Harbor: creating harbor-ca-bundle from platform-tls"
    local tmp_cert
    tmp_cert=$(mktemp)
    kubectl get secret platform-tls -n harbor -o jsonpath='{.data.tls\.crt}' | base64 -d > "$tmp_cert"
    if [[ ! -s "$tmp_cert" ]]; then
      rm -f "$tmp_cert"
      die "platform-tls secret in harbor namespace has no tls.crt — see README's platform-tls section"
    fi
    kubectl -n harbor create secret generic harbor-ca-bundle --from-file=ca.crt="$tmp_cert"
    rm -f "$tmp_cert"
  fi

  # caBundleSecretName is only read at pod start (volume mount). Argo CD's
  # own sync of that Helm value already triggered a rollout of core/
  # jobservice/registry/trivy — those pods are what's stuck ContainerCreating
  # until harbor-ca-bundle exists (just created above, or on an earlier run).
  # No explicit restart needed; just wait for that already-in-flight rollout.
  log "Harbor: waiting for core/jobservice/registry/trivy to become Ready"
  kubectl -n harbor rollout status deployment/harbor-core --timeout=180s
  kubectl -n harbor rollout status deployment/harbor-jobservice --timeout=180s
  kubectl -n harbor rollout status deployment/harbor-registry --timeout=180s
  kubectl -n harbor rollout status statefulset/harbor-trivy --timeout=180s

  log "Harbor: configuring OIDC auth mode via the Configurations API"
  local tmp_resp http_code
  tmp_resp=$(mktemp)
  http_code=$(curl -sk -o "$tmp_resp" -w '%{http_code}' -u "$HARBOR_ADMIN_USER:$HARBOR_ADMIN_PASS" -X PUT \
    "$HARBOR_URL/api/v2.0/configurations" \
    -H "Content-Type: application/json" \
    -d "{
          \"auth_mode\": \"oidc_auth\",
          \"oidc_name\": \"Keycloak\",
          \"oidc_endpoint\": \"$KEYCLOAK_ISSUER\",
          \"oidc_client_id\": \"harbor\",
          \"oidc_client_secret\": \"dev-harbor-oidc-secret-change-me\",
          \"oidc_scope\": \"openid,profile,email\",
          \"oidc_verify_cert\": true,
          \"oidc_auto_onboard\": true,
          \"oidc_user_claim\": \"preferred_username\",
          \"oidc_admin_group\": \"argocd-admins\",
          \"oidc_groups_claim\": \"groups\"
        }")
  if [[ "$http_code" != "200" ]]; then
    cat "$tmp_resp" >&2
    rm -f "$tmp_resp"
    die "Harbor configurations API returned HTTP $http_code"
  fi
  rm -f "$tmp_resp"

  log "Harbor OIDC login ready — $HARBOR_URL (LOGIN VIA OIDC PROVIDER)"
}

target="${1:-all}"
case "$target" in
  openbao) enable_openbao_oidc ;;
  harbor)  enable_harbor_oidc ;;
  all)     enable_openbao_oidc; enable_harbor_oidc ;;
  *) die "usage: $0 [openbao|harbor|all]" ;;
esac
