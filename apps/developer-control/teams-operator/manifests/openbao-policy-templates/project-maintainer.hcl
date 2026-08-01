# OpenBao ACL policy for namespace {{ NAMESPACE }}: full read/write access to
# this namespace's slice of the layered kv KV-v2 mount, plus the project's
# shared bucket. Rendered by ensure_openbao_access (teams_operator.py) and PUT
# to sys/policies/acl/{{ NAMESPACE }}-maintainer-policy as
# {"policy": "<this file>"}.
#
# Two separate identities carry this policy: this namespace's workload SPIFFE
# identities (via the JWT auth role - see project-maintainer.json) and anyone
# in the "{{ NAMESPACE }}-maintainer" Keycloak group logging in via OIDC SSO
# (see bootstrap/README.md's OpenBao OIDC section - the group-alias binding is
# what wires that up).
#
# Path layout (see docs/self-service-repos-github-app.md): namespaces nest
# UNDER the project slug so an owner-wide glob is safe. {{ SLUG }} is the
# project's argocd_project slug; {{ NAMESPACE }} is the full
# project-<slug>-<label> namespace name. Isolation comes from the path, not a
# separate mount per project.

# This namespace's own secrets.
path "kv/data/projects/{{ SLUG }}/namespaces/{{ NAMESPACE }}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/projects/{{ SLUG }}/namespaces/{{ NAMESPACE }}/*" {
  capabilities = ["read", "list", "delete"]
}

# The project-wide shared bucket, readable+writable by every maintainer of any
# namespace in the project.
path "kv/data/projects/{{ SLUG }}/namespaces/shared/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/projects/{{ SLUG }}/namespaces/shared/*" {
  capabilities = ["read", "list", "delete"]
}
