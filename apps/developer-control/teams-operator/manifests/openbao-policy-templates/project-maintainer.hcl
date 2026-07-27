# OpenBao ACL policy for namespace {{ NAMESPACE }}: full read/write access
# to this namespace's slice of the shared kv-teams KV-v2 mount. Rendered by
# ensure_openbao_access (teams_operator.py) and PUT to
# sys/policies/acl/{{ NAMESPACE }}-maintainer-policy as
# {"policy": "<this file>"}.
#
# Two separate identities carry this policy: this namespace's workload
# SPIFFE identities (via the JWT auth role - see project-maintainer.json)
# and anyone in the "{{ NAMESPACE }}-maintainer" Keycloak group logging in
# via OIDC SSO (see bootstrap/README.md's OpenBao OIDC section - the
# group-alias binding is what wires that up). Isolation comes from the
# path, not a separate mount per project (see bootstrap/README.md's
# OpenBao JWT-auth section for why one mount).
path "kv-teams/data/{{ NAMESPACE }}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv-teams/metadata/{{ NAMESPACE }}/*" {
  capabilities = ["read", "list", "delete"]
}
