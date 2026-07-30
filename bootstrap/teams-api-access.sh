#!/usr/bin/env bash
# (Re)create the teams-api-k8s-access ConfigMap that teams-api reads to serve
# GET /kubeconfig (the "download kubeconfig" button in teams-ui / `teams-cli
# kubeconfig`). It carries two keys, sourced live from the CURRENT kubectl
# context, so nothing is hardcoded:
#   server  - the apiserver URL (Docker assigns the kind host port dynamically;
#             it changes on every cluster recreate)
#   ca.crt  - the cluster CA in PEM (decoded from the context's
#             certificate-authority-data)
#
# This ConfigMap is intentionally NOT in git (the port is per-cluster) and is
# wiped by a `kind delete` + recreate, at which point teams-api's env resolves
# empty and GET /kubeconfig returns 503. Re-run this to fix it. See
# bootstrap/README.md "kubectl access via Keycloak (OIDC)" step 1.
#
# Idempotent: uses create --dry-run=client | apply, then restarts teams-api so
# it re-reads the values (they're injected as env vars, only read at pod start).
set -euo pipefail

TEAMS_NS="${TEAMS_NS:-engineering-platform}"

echo ">> sourcing apiserver URL + CA from the current kubectl context:"
kubectl config current-context

server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
kubectl config view --minify --raw \
  -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$tmp"

echo ">> applying ConfigMap teams-api-k8s-access (server=$server) in ns $TEAMS_NS"
kubectl -n "$TEAMS_NS" create configmap teams-api-k8s-access \
  --from-literal=server="$server" \
  --from-file=ca.crt="$tmp" \
  --dry-run=client -o yaml | kubectl apply -f -

echo ">> restarting teams-api so it re-reads the ConfigMap env"
kubectl -n "$TEAMS_NS" rollout restart deploy/teams-api
