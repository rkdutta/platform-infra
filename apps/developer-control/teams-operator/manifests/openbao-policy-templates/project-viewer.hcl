# OpenBao ACL policy for namespace {{ NAMESPACE }}: read-only access to this
# namespace's slice of the shared kv KV-v2 mount. Rendered by
# ensure_openbao_access (teams_operator.py) and PUT to
# sys/policies/acl/{{ NAMESPACE }}-viewer-policy as {"policy": "<this
# file>"}.
#
# Granted to anyone in the "{{ NAMESPACE }}-viewer" Keycloak group logging
# in via OIDC SSO (see bootstrap/README.md's OpenBao OIDC section) - the
# read-only counterpart to project-maintainer.hcl. No workload identity
# uses this policy; tenant pods always authenticate as maintainer-level
# (see project-maintainer.json) since they need to write their own secrets.
path "kv/data/{{ NAMESPACE }}/*" {
  capabilities = ["read", "list"]
}

path "kv/metadata/{{ NAMESPACE }}/*" {
  capabilities = ["read", "list"]
}
