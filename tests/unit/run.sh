#!/usr/bin/env bash
# platform-infra unit tests: static/local checks, no live cluster needed.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source tests/lib.sh

check "application-manifests-schema" "tests/unit/check_applications.py" -- python3 tests/unit/check_applications.py
check "keycloak-realm-roles-in-sync" "tests/unit/check_keycloak_realm_sync.py" -- python3 tests/unit/check_keycloak_realm_sync.py

# --- every bootstrap script parses cleanly -----------------------------------
bootstrap_scripts_parse() {
  local f
  for f in bootstrap/*.sh; do
    bash -n "$f" || { echo "$f: syntax error"; return 1; }
  done
}
check "bootstrap-scripts-syntax" "bootstrap/*.sh" -- bootstrap_scripts_parse

# --- every bootstrap script has a shebang (gotcha: zsh word-splitting bites
# scripts that don't reliably run under bash — found openbao.sh missing one) -
bootstrap_scripts_have_shebang() {
  local f
  for f in bootstrap/*.sh; do
    head -1 "$f" | grep -q "^#!.*bash" || { echo "$f: missing a bash shebang"; return 1; }
  done
}
check "bootstrap-scripts-have-shebang" "bootstrap/*.sh" -- bootstrap_scripts_have_shebang

# --- kubectl exec needs -i to forward heredoc stdin (gotcha) -----------------
heredocs_use_exec_i() {
  local f
  for f in bootstrap/*.sh; do
    if grep -qE "<<-?'?EOF'?" "$f"; then
      grep -q "exec -i" "$f" || { echo "$f: has a heredoc but no 'exec -i' anywhere in the file"; return 1; }
    fi
  done
}
check "heredocs-use-exec-i" "bootstrap/*.sh" -- heredocs_use_exec_i

# --- make -n bootstrap dry-runs cleanly (catches Makefile syntax errors and,
# combined with the grep below, silently-dropped bootstrap steps) -----------
check "make-bootstrap-dry-run" "bootstrap/Makefile" -- make -n -C bootstrap bootstrap

# --- the bootstrap target must still include the Harbor/Ratify steps that
# were once silently missing (gotcha, found + fixed this session) -----------
bootstrap_target_complete() {
  local recipe
  recipe=$(awk '/^bootstrap:/{f=1;next} /^[a-zA-Z_-]+:/{f=0} f' bootstrap/Makefile)
  for step in ratify-harbor-pull harbor-sso harbor-pull openbao-access teams-api-access; do
    echo "$recipe" | grep -q "$step" || { echo "bootstrap target is missing the '$step' step"; return 1; }
  done
}
check "bootstrap-target-complete" "bootstrap/Makefile" -- bootstrap_target_complete

# --- openbao.sh must still restart the unseal watcher after creating its
# Secret (gotcha, found + fixed this session) --------------------------------
check "openbao-unseal-restart-present" "bootstrap/openbao.sh" -- grep -q "app.kubernetes.io/name=openbao-unseal" bootstrap/openbao.sh

# --- teams-* Deployments must keep imagePullPolicy: IfNotPresent (gotcha: the
# `kind load docker-image` fallback is a no-op otherwise) -------------------
image_pull_policy_ok() {
  local f
  for f in apps/developer-control/teams-api/manifests/deployment.yaml \
           apps/developer-control/teams-app/manifests/deployment.yaml \
           apps/developer-control/teams-operator/manifests/deployment.yaml; do
    grep -q "imagePullPolicy: IfNotPresent" "$f" || { echo "$f: not IfNotPresent"; return 1; }
  done
}
check "teams-deployments-image-pull-policy" "apps/developer-control/*/manifests/deployment.yaml" -- image_pull_policy_ok

report
