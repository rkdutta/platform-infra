#!/usr/bin/env bash
# Find every workload pod in the cluster holding a SPIRE-issued JWT-SVID on
# disk, and decode it. Generalizes the one-off:
#   kubectl -n engineering-platform exec -it deployments/teams-operator \
#     -c teams-operator -- cat /operator-shared/spiffe-jwt | jwt decode -
#
# Every component that gets a JWT-SVID in this cluster (teams-operator,
# any tenant workload opted into `platform.example.com/openbao-access:
# "true"` — see docs/openbao-spiffe-access.md) does it via the same
# `spiffe-helper` sidecar, which writes the SVID into an emptyDir shared
# with one other container in the same pod (tenant pods: openbao-agent,
# volume openbao-agent-shared; teams-operator: the main teams-operator
# container, volume operator-spiffe-shared).
#
# `spiffe-helper`'s own image is distroless (no shell, no cat/ls — confirmed
# empirically, `kubectl exec -c spiffe-helper` fails with "exec: sh: not
# found"), so this can't just exec into it. Instead it finds, per pod, the
# *other* container that mounts the same emptyDir volume spiffe-helper
# writes into, and execs there:
#   1. find every Running pod with a container named `spiffe-helper` (that
#      container's presence IS the marker "this pod holds an SVID"),
#   2. from the pod spec (already fetched, no extra API calls), find which
#      emptyDir volume spiffe-helper mounts, then which other container in
#      the same pod also mounts that volume, and at what path — this is
#      fully generic, no hardcoded container names/paths per component,
#   3. list whatever files are actually there, decode anything shaped like
#      a JWT (three dot-separated base64url segments) — naturally skips
#      openbao-agent's sibling /shared/bao-token on tenant pods, which is
#      an opaque OpenBao token, not a JWT.
#
# Decoding prefers the `jwt` CLI (mike-engel/jwt-cli — `jwt decode -`) if
# it's on PATH, since that's already the tool in the one-off command above;
# falls back to a plain python3 base64url decode (header + payload, no sig
# verification either way — this is a read-only inspection script, not an
# auth check) if `jwt` isn't installed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: inspect-svids.sh [-n NAMESPACE] [POD_SUBSTRING] [--raw]

  (no args)         Scan every namespace for pods with a spiffe-helper
                     sidecar; decode every JWT-shaped file in their /shared.
  -n NAMESPACE       Restrict the scan to one namespace.
  POD_SUBSTRING      Only inspect pods whose name contains this substring.
  --raw              Print the raw JWT (still filtered to JWT-shaped files)
                     instead of decoding it — useful for piping elsewhere.

Examples:
  inspect-svids.sh                          # every SVID in the cluster
  inspect-svids.sh -n engineering-platform  # just teams-operator's
  inspect-svids.sh demo-api-go              # just that tenant workload
EOF
}

ns_filter=""
pod_substring=""
raw=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) ns_filter="$2"; shift 2 ;;
    --raw) raw=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) pod_substring="$1"; shift ;;
  esac
done

jwt_shape='^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$'

decode() {
  local token="$1"
  if $raw; then
    echo "$token"
    return
  fi
  if command -v jwt >/dev/null 2>&1; then
    echo "$token" | jwt decode -
    return
  fi
  python3 - "$token" <<'PY'
import sys, json, base64

def pad(s):
    return s + "=" * (-len(s) % 4)

token = sys.argv[1]
header, payload, _sig = token.split(".")
print("Token header")
print("------------")
print(json.dumps(json.loads(base64.urlsafe_b64decode(pad(header))), indent=2))
print()
print("Token claims")
print("------------")
print(json.dumps(json.loads(base64.urlsafe_b64decode(pad(payload))), indent=2))
PY
}

get_pods_json() {
  if [[ -n "$ns_filter" ]]; then
    kubectl -n "$ns_filter" get pods -o json
  else
    kubectl get pods -A -o json
  fi
}

# For each pod with a spiffe-helper container, resolve which OTHER container
# in that same pod shares spiffe-helper's emptyDir volume, and at what mount
# path — that's the container we can actually exec/cat through.
targets="$(get_pods_json | jq -r '
  .items[]
  | select(.status.phase == "Running")
  | . as $pod
  | ($pod.spec.containers[] | select(.name=="spiffe-helper")) as $sh
  | (($sh.volumeMounts // [])[]) as $shmount
  | ($pod.spec.volumes[]? | select(.name==$shmount.name and .emptyDir != null)) as $vol
  | ($pod.spec.containers[]
      | select(.name != "spiffe-helper")
      | select(((.volumeMounts // [])[]?.name) == $vol.name)) as $other
  | (($other.volumeMounts[]? | select(.name==$vol.name))) as $othermount
  | [$pod.metadata.namespace, $pod.metadata.name, $other.name, $othermount.mountPath] | @tsv
')"

if [[ -z "$targets" ]]; then
  echo "No Running pods with a spiffe-helper sidecar found${ns_filter:+ in namespace $ns_filter}." >&2
  exit 0
fi

found_any=false
while IFS=$'\t' read -r ns pod container mountpath; do
  [[ -n "$pod_substring" && "$pod" != *"$pod_substring"* ]] && continue

  files="$(kubectl -n "$ns" exec "$pod" -c "$container" -- sh -c "ls '$mountpath' 2>/dev/null" || true)"
  [[ -z "$files" ]] && continue

  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    content="$(kubectl -n "$ns" exec "$pod" -c "$container" -- sh -c "cat '$mountpath/$f' 2>/dev/null" || true)"
    [[ "$content" =~ $jwt_shape ]] || continue

    found_any=true
    echo "=== $ns/$pod  ($mountpath/$f, via -c $container) ==="
    decode "$content"
    echo
  done <<< "$files"
done <<< "$targets"

if ! $found_any; then
  echo "Found spiffe-helper sidecars, but no JWT-shaped file in /shared on any of them" \
       "(SVID may not have been issued yet — check spiffe-helper's own logs)." >&2
fi
