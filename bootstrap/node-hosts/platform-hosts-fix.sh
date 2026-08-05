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

# Both Keycloak and Harbor are reached FROM THE NODE via host.docker.internal,
# which forwards to the host-level docker port maps back to the ingress:
#   - Keycloak issuer is on :8443 (host:8443 -> node:443).
#   - Harbor: containerd pulls on :443 (host:443 -> node:443) and then follows
#     Harbor's token realm to :8443 (host:8443 -> node:443). BOTH host ports
#     map to the ingress (see platform-base main.tf extra_port_mappings), so a
#     single host.docker.internal route serves both the pull and the token
#     fetch — which the in-cluster ClusterIP (443 only) could not.
# Resolved fresh at boot so it survives host IP changes.
DOCKER_HOST_IP="$(getent hosts host.docker.internal | awk '{print $1}')"
add "$DOCKER_HOST_IP" platform-auth.127.0.0.1.sslip.io
add "$DOCKER_HOST_IP" harbor.127.0.0.1.sslip.io
