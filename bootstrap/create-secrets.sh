#!/usr/bin/env bash
# =============================================================================
# create-secrets.sh — create all out-of-band (git-ignored) secrets a freshly
# provisioned cluster needs. Idempotent: safe to re-run.
#
# Run AFTER `terraform apply` (platform-base has created the kind cluster +
# Argo CD) and BEFORE `kubectl apply -f bootstrap/root-app.yaml` — the Argo repo
# credentials must exist before the app-of-apps tries to sync the private repos.
#
# Covers:
#   1. Argo CD repository credentials  (namespace: argocd)
#   2. platform-tls wildcard cert      (namespaces: openbao harbor keycloak
#                                        engineering-platform)
#   3. GHCR pull credentials           (namespace: harbor)
#
# Secret VALUES live in git-ignored files (repo-credentials*.yaml,
# harbor-replication/ghcr-credentials.yaml) and in a generated platform-tls
# cert/key. This script contains NO secrets itself.
#
# Usage:
#   ./create-secrets.sh [all|repo-creds|tls|ghcr]      (default: all)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[1;33m•\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Namespaces that host an Ingress referencing secretName: platform-tls.
PLATFORM_TLS_NS="openbao harbor keycloak engineering-platform"

# Persisted cert/key location (git-ignored) so the SAME self-signed cert is
# reused across cluster rebuilds — keeping the containerd/apiserver/OpenBao CA
# trust that copied it valid. Override with PLATFORM_TLS_CERT / PLATFORM_TLS_KEY.
TLS_CRT="${PLATFORM_TLS_CERT:-$SCRIPT_DIR/platform-tls.crt}"
TLS_KEY="${PLATFORM_TLS_KEY:-$SCRIPT_DIR/platform-tls.key}"

require_cluster() {
  command -v kubectl >/dev/null || die "kubectl not found in PATH"
  kubectl cluster-info >/dev/null 2>&1 || die "kubectl cannot reach a cluster (check your context)"
  log "Target context: $(kubectl config current-context)"
}

ensure_ns() {  # ensure_ns <namespace> — created bare if missing; Argo adopts it later.
  kubectl get ns "$1" >/dev/null 2>&1 || kubectl create ns "$1" >/dev/null
}

# ---- 1. Argo CD repository credentials --------------------------------------
apply_repo_creds() {
  log "Argo CD repository credentials (namespace: argocd)"
  ensure_ns argocd

  # Required: without this, root-app cannot authenticate to the private GitOps repo.
  if [ -f "$SCRIPT_DIR/repo-credentials.yaml" ]; then
    kubectl apply -f "$SCRIPT_DIR/repo-credentials.yaml" >/dev/null
    ok "platform-infra repo creds"
  else
    die "$SCRIPT_DIR/repo-credentials.yaml missing (git-ignored).
       Copy repo-credentials-example.yaml -> repo-credentials.yaml and fill in your GitHub PAT."
  fi

  # Optional: demo application repos.
  for f in repo-credentials-demo-go.yaml repo-credentials-demo-py.yaml; do
    if [ -f "$SCRIPT_DIR/$f" ]; then
      kubectl apply -f "$SCRIPT_DIR/$f" >/dev/null; ok "$f"
    else
      skip "$f not present — its demo repos won't sync (optional)"
    fi
  done
}

# ---- 2. platform-tls wildcard cert ------------------------------------------
apply_platform_tls1() {}
apply_platform_tls() {
  log "platform-tls wildcard cert for *.127.0.0.1.sslip.io"
  command -v openssl >/dev/null || die "openssl not found in PATH"

  if [ -f "$TLS_CRT" ] && [ -f "$TLS_KEY" ]; then
    ok "reusing existing cert at $TLS_CRT"
  else
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
      -keyout "$TLS_KEY" -out "$TLS_CRT" \
      -subj "/CN=*.127.0.0.1.sslip.io" \
      -addext "subjectAltName=DNS:*.127.0.0.1.sslip.io,DNS:127.0.0.1.sslip.io" 2>/dev/null
    chmod 600 "$TLS_KEY"
    ok "generated new cert -> $TLS_CRT (+ .key, git-ignored)"
  fi

  for ns in $PLATFORM_TLS_NS; do
    ensure_ns "$ns"
    kubectl -n "$ns" create secret tls platform-tls \
      --cert="$TLS_CRT" --key="$TLS_KEY" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    ok "platform-tls in $ns"
  done
}

# ---- 3. GHCR pull credentials for harbor-replication ------------------------
apply_ghcr() {
  log "GHCR pull credentials (namespace: harbor)"
  local f="$INFRA_DIR/apps/integration-delivery/harbor-replication/ghcr-credentials.yaml"
  if [ -f "$f" ]; then
    ensure_ns harbor
    kubectl apply -f "$f" >/dev/null; ok "ghcr-replication-credentials"
  else
    skip "ghcr-credentials.yaml not present — Harbor GHCR replication won't authenticate.
       Copy ghcr-credentials.example.yaml -> ghcr-credentials.yaml and fill in a read:packages PAT."
  fi
}

main() {
  require_cluster
  case "${1:-all}" in
    all)        apply_repo_creds; apply_platform_tls1; apply_ghcr ;;
    repo-creds) apply_repo_creds ;;
    tls)        apply_platform_tls ;;
    ghcr)       apply_ghcr ;;
    *)          die "unknown target '$1' (use: all | repo-creds | tls | ghcr)" ;;
  esac
  log "Done. Next: kubectl apply -f projects/ && kubectl apply -f bootstrap/root-app.yaml"
}

main "$@"
