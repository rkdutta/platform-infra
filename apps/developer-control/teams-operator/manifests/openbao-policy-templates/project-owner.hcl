# OpenBao ACL policy for project {{ SLUG }}: full read/write access to the
# ENTIRE project subtree - the project-management level, the shared bucket, and
# every one of the project's namespaces (present and future). Rendered by
# ensure_openbao_access (teams_operator.py) and PUT to
# sys/policies/acl/project-{{ SLUG }}-owner-policy.
#
# Carried by anyone in the "project-{{ SLUG }}-owner" Keycloak group (the
# project's owners / project-managers) logging in via OIDC SSO - the operator
# syncs DB project owners into that group and binds the group-alias. The single
# glob covers namespaces added later with no re-render; it is safe against
# cross-project bleed because the literal /{{ SLUG }}/ path segment cannot match
# a different slug (see docs/self-service-repos-github-app.md).

path "kv/data/projects/{{ SLUG }}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv/metadata/projects/{{ SLUG }}/*" {
  capabilities = ["read", "list", "delete"]
}
