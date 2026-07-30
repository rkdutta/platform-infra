#!/usr/bin/env bash
# Enable the KV-v2 secrets engine at path kv/ (idempotent). This is OpenBao
# runtime state wiped by a cluster/PVC recreate — step 1 of the "OpenBao —
# one-time init" section of bootstrap/README.md. teams-operator and the
# teams-app UI address secrets at kv/data/<namespace>/... and
# kv/metadata/<namespace>/... (KV v2), path-isolated per project.
#
# Prereq: OpenBao initialised/unsealed (bootstrap/init-keys.json present).
# Usage: bootstrap/enable-openbao-kv.sh
set -euo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m==>\033[0m %s\n' "$1"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$1" >&2; exit 1; }

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "'$bin' is required on PATH"
done

[[ -f bootstrap/init-keys.json ]] \
  || die "bootstrap/init-keys.json not found — run the OpenBao init steps in README.md first"
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)
[[ -n "$BAO_TOKEN" && "$BAO_TOKEN" != "null" ]] \
  || die "could not read .root_token from bootstrap/init-keys.json"

bao() { kubectl -n openbao exec -i openbao-0 -- sh -c "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN $*"; }

if bao 'bao secrets list -format=json' | jq -e '."kv/"' >/dev/null 2>&1; then
  log "kv/ secrets engine already enabled, skipping"
else
  log "enabling kv-v2 secrets engine at path kv/"
  bao 'bao secrets enable -path=kv kv-v2'
fi
