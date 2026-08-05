#!/usr/bin/env bash
# Black-box "does self-service actually work" test: create a project via the
# live teams-api, confirm teams-operator reconciles every target it owns
# (RBAC, Argo CD RBAC, OpenBao policy/role, Harbor pull secret), delete it,
# confirm full teardown. Mutates live state (creates + deletes a real test
# project) — not bundled into tests/e2e/run.sh's read-only sweep; run this
# separately.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source tests/lib.sh

TEAMS_API_URL="${TEAMS_API_URL:-https://teams-api.127.0.0.1.sslip.io:8443}"
KEYCLOAK_ISSUER="${KEYCLOAK_ISSUER:-https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams}"
E2E_CLIENT_SECRET="${E2E_CLIENT_SECRET:-dev-teams-e2e-tests-secret-change-me}"
PROJECT_NAME="e2eciteste2e$RANDOM"
NAMESPACE="project-${PROJECT_NAME}-default"
TIMEOUT=90
POLL=3

token() {
  curl -sk -X POST "$KEYCLOAK_ISSUER/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=teams-e2e-tests" -d "client_secret=$E2E_CLIENT_SECRET" \
    -d "username=admin" -d "password=admin123" | python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])'
}

TOKEN=$(token)
if [ -z "$TOKEN" ]; then
  echo "FAIL: 0/0 (0%)"
  echo "  setup :: teams-e2e-tests client :: could not obtain a token — is Keycloak reachable and the client present?"
  exit 1
fi

api() { curl -sk -H "Authorization: Bearer $TOKEN" "$@"; }

wait_for() {  # wait_for <description> <command...>
  local desc="$1"; shift
  local waited=0
  until "$@" >/dev/null 2>&1; do
    waited=$((waited + POLL))
    [ "$waited" -ge "$TIMEOUT" ] && { echo "timed out waiting for: $desc"; return 1; }
    sleep "$POLL"
  done
}

# --- create ------------------------------------------------------------------
create_resp=$(api -X POST "$TEAMS_API_URL/projects" -H "Content-Type: application/json" \
  -d "{\"name\": \"$PROJECT_NAME\"}")
project_id=$(echo "$create_resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null)
check "create-project" "main.py:create_project" -- test -n "$project_id"

if [ -z "$project_id" ]; then
  echo "create failed, response: $create_resp" >&2
  report
fi

check "namespace-created" "teams_operator.py:create_namespace" -- wait_for "namespace $NAMESPACE" kubectl get ns "$NAMESPACE"
check "rolebinding-viewer" "teams_operator.py:_ensure_group_role_binding" -- wait_for "RoleBinding teams-sync-viewer" kubectl -n "$NAMESPACE" get rolebinding teams-sync-viewer
check "rolebinding-maintainer" "teams_operator.py:_ensure_group_role_binding" -- wait_for "RoleBinding teams-sync-maintainer" kubectl -n "$NAMESPACE" get rolebinding teams-sync-maintainer
check "argocd-rbac-line" "teams_operator.py:_argocd_project_policy_block" -- wait_for "argocd-rbac-cm g-line for $NAMESPACE" \
  bash -c "kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' | grep -q '${NAMESPACE}-maintainer'"
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json 2>/dev/null || true)
openbao_policy_exists() {
  kubectl -n openbao exec openbao-0 -- sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao policy read $1" >/dev/null 2>&1
}
check "openbao-maintainer-policy" "teams_operator.py:ensure_openbao_access" -- wait_for "OpenBao policy ${NAMESPACE}-maintainer-policy" \
  openbao_policy_exists "${NAMESPACE}-maintainer-policy"
check "harbor-pull-secret" "teams_operator.py" -- wait_for "harbor-pull secret in $NAMESPACE" kubectl -n "$NAMESPACE" get secret harbor-pull

# --- delete + teardown ---------------------------------------------------------
api -X DELETE "$TEAMS_API_URL/projects/$project_id" >/dev/null
check "namespace-deleted" "teams_operator.py:delete_namespace" -- wait_for "namespace $NAMESPACE gone" bash -c "! kubectl get ns '$NAMESPACE' >/dev/null 2>&1"
check "argocd-rbac-line-removed" "teams_operator.py:delete_namespace" -- wait_for "argocd-rbac-cm g-line for $NAMESPACE gone" \
  bash -c "! kubectl -n argocd get cm argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' | grep -q '${NAMESPACE}-maintainer'"
check "openbao-policy-removed" "teams_operator.py:delete_openbao_access" -- wait_for "OpenBao policy ${NAMESPACE}-maintainer-policy gone" \
  bash -c "! openbao_policy_exists '${NAMESPACE}-maintainer-policy'"

report
