#!/usr/bin/env bash
# platform-infra e2e tests: confirm the LIVE cluster's platform services are
# actually up and correctly configured. Needs a reachable kind cluster (the
# current kubectl context).
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source tests/lib.sh

HARBOR_URL="${HARBOR_URL:-https://harbor.127.0.0.1.sslip.io:8443}"
HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD:-Harbor12345}"
KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams}"

# --- every non-demo Argo Application is Healthy -----------------------------
# (demo-* apps are separate repos with their own lifecycle, out of scope here)
argo_apps_healthy() {
  local unhealthy
  unhealthy=$(kubectl -n argocd get applications -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
bad = [i["metadata"]["name"] for i in d["items"]
       if not i["metadata"]["name"].startswith("demo-")
       and i.get("status", {}).get("health", {}).get("status") != "Healthy"]
print(",".join(bad))
')
  [ -z "$unhealthy" ] || { echo "unhealthy Applications: $unhealthy"; return 1; }
}
check "argo-applications-healthy" "apps/**/application.yaml" -- argo_apps_healthy

# --- OpenBao unsealed --------------------------------------------------------
openbao_unsealed() {
  local sealed
  sealed=$(kubectl -n openbao exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json' 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sealed"])')
  [ "$sealed" = "False" ] || { echo "OpenBao is sealed"; return 1; }
}
check "openbao-unsealed" "apps/security/openbao" -- openbao_unsealed

# --- OpenBao's dangerous unauthenticated generate-root endpoints must stay
# disabled (gotcha: this was intentionally flipped during the root-token
# recovery incident and must not be left that way) ---------------------------
generate_root_endpoints_disabled() {
  local hcl
  hcl=$(kubectl -n openbao get cm openbao-config -o jsonpath='{.data.extraconfig-from-values\.hcl}')
  ! echo "$hcl" | grep -Eq 'disable_unauthed_generate_root_endpoints[[:space:]]*=[[:space:]]*false' \
    || { echo "disable_unauthed_generate_root_endpoints=false is still set — revert it"; return 1; }
}
check "openbao-generate-root-disabled" "apps/security/openbao" -- generate_root_endpoints_disabled

# --- Keycloak realm reachable -------------------------------------------------
check "keycloak-realm-reachable" "apps/security/keycloak" -- bash -c \
  "[ \"\$(curl -sk -o /dev/null -w '%{http_code}' '$KEYCLOAK_ISSUER/.well-known/openid-configuration')\" = 200 ]"

# --- Harbor reachable + OIDC login live (not just local admin/password) -----
check "harbor-oidc-live" "apps/integration-delivery/harbor" -- bash -c \
  "[ \"\$(curl -sk -u admin:$HARBOR_ADMIN_PASSWORD '$HARBOR_URL/api/v2.0/configurations' | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"auth_mode\"][\"value\"])')\" = oidc_auth ]"

# --- ratify-admin still has its Harbor pull secret (gotcha, found + fixed
# this session — nothing in the Makefile used to create it) ------------------
check "ratify-harbor-pull-wired" "apps/security/ratify" -- bash -c \
  "[ -n \"\$(kubectl -n gatekeeper-system get sa ratify-admin -o jsonpath='{.imagePullSecrets}')\" ]"

# --- SPIRE bundle configmap present ------------------------------------------
check "spire-bundle-present" "apps/security/spire" -- kubectl -n spire-server get cm spire-bundle

# --- SPIRE OIDC discovery provider cert covers the full svc.cluster.local
# FQDN (gotcha: dnsNameTemplates fix; regresses to a SAN-mismatch TLS error
# for OpenBao's jwt auth if this ever reverts) --------------------------------
spire_discovery_cert_san_ok() {
  local sans
  sans=$(kubectl -n spire-server get secret spire-spiffe-oidc-discovery-provider-cert -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -text | grep "Subject Alternative Name" -A1 | tail -1)
  echo "$sans" | grep -q "spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local" \
    || { echo "discovery provider cert SAN missing the full svc.cluster.local FQDN: $sans"; return 1; }
}
check "spire-discovery-cert-san" "apps/security/spire/application.yaml" -- spire_discovery_cert_san_ok

# --- no live Deployment still points at the stale olivercodes01 placeholder -
no_stale_images() {
  local hits
  hits=$(kubectl get deploy -A -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' \
    | grep -i olivercodes01 || true)
  [ -z "$hits" ] || { echo "live Deployment(s) using an olivercodes01 image: $hits"; return 1; }
}
check "no-stale-placeholder-images-live" "apps/developer-control/*" -- no_stale_images

report
