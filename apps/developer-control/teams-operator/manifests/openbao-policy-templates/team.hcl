# OpenBao ACL policy for namespace {{ NAMESPACE }}. Rendered by
# ensure_openbao_access (teams_operator.py) and PUT to
# sys/policies/acl/team-{{ NAMESPACE }} as {"policy": "<this file>"}.
#
# Scoped to exactly this namespace's slice of the shared kv-teams KV-v2
# mount - isolation comes from the path, not from a separate mount per team
# (see bootstrap/README.md's OpenBao JWT-auth section for why one mount).
path "kv-teams/data/{{ NAMESPACE }}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

path "kv-teams/metadata/{{ NAMESPACE }}/*" {
  capabilities = ["read", "list", "delete"]
}
