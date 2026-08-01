#!/usr/bin/env bash
# Seed the platform GitHub App credentials into OpenBao at kv/platform/github-app
# (see docs/self-service-repos-github-app.md). This is the ONLY place the App
# private key lives; teams-operator reads it (platform-operator-policy) to
# materialize Argo CD githubApp repository Secrets. teams-api never sees it.
#
# Idempotent: a re-run overwrites the values (e.g. after rotating the key).
# Run it yourself — it needs the OpenBao root token and your downloaded .pem;
# nothing here is committed to git.
#
# Usage:
#   bootstrap/seed-github-app.sh <APP_ID> <PATH_TO_PRIVATE_KEY.pem>
# Example:
#   bootstrap/seed-github-app.sh 4450687 ~/Downloads/rkdutta-engineering-platform.2026-07-31.private-key.pem
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_ID="${1:-}"
PEM_PATH="${2:-}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

[[ -n "$APP_ID" ]]   || die "APP_ID is required (arg 1)"
[[ -n "$PEM_PATH" ]] || die "path to the .pem private key is required (arg 2)"
# Expand a leading ~ ourselves (it isn't expanded when passed quoted).
PEM_PATH="${PEM_PATH/#\~/$HOME}"
[[ -s "$PEM_PATH" ]] || die "private key file not found or empty: $PEM_PATH"

[[ -f bootstrap/init-keys.json ]] \
  || die "bootstrap/init-keys.json not found — run the OpenBao init steps in README.md first"
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)
[[ -n "$BAO_TOKEN" && "$BAO_TOKEN" != "null" ]] \
  || die "could not read .root_token from bootstrap/init-keys.json"

log "copying private key into openbao-0 (transient /tmp, removed after write)"
kubectl -n openbao cp "$PEM_PATH" openbao-0:/tmp/gh-app.pem

log "writing kv/platform/github-app (app_id + private_key)"
kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN \
     bao kv put kv/platform/github-app app_id=$APP_ID private_key=@/tmp/gh-app.pem"

kubectl -n openbao exec openbao-0 -- rm -f /tmp/gh-app.pem

log "done — teams-operator will pick this up on its next reconcile poll"
