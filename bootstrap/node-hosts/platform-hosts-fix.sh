#!/bin/sh
# Restore node /etc/hosts routing for the *.127.0.0.1.sslip.io names that must
# be reachable FROM THE NODE ITSELF (not from pods, which use CoreDNS):
#   - kube-apiserver (hostNetwork static pod) -> Keycloak, for OIDC token
#     validation (fetching discovery/JWKS).
#   - containerd -> Harbor, for pulling tenant images.
#
# Docker rewrites /etc/hosts on every container start, wiping manual edits, so
# this runs as a systemd oneshot BEFORE kubelet on every boot. Idempotent.
set -eu
HOSTS=/etc/hosts

add() {  # add <ip> <name>
  ip="$1"; name="$2"
  if [ -z "$ip" ]; then echo "skip $name: could not resolve target ip"; return 0; fi
  if grep -q " $name\$" "$HOSTS" 2>/dev/null || grep -q " $name " "$HOSTS" 2>/dev/null; then
    echo "present: $name"
  else
    echo "$ip $name" >> "$HOSTS"
    echo "added:   $ip $name"
  fi
}

# Keycloak issuer is on :8443, which exists only as a HOST-level docker port
# map (host:8443 -> node:443); host.docker.internal reaches it. Resolved fresh
# at boot so it survives host IP changes.
add "$(getent hosts host.docker.internal | awk '{print $1}')" platform-auth.127.0.0.1.sslip.io

# Harbor registry -> in-cluster ingress, via the ingress-nginx ClusterIP.
# NOTE: pin this value (see companion note) so it is stable across cluster
# recreation. Current ingress-nginx-controller ClusterIP:
add "10.96.209.177" harbor.127.0.0.1.sslip.io
