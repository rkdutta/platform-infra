# OpenBao secret organization & who can access what

How the platform's secrets are laid out in OpenBao's `kv` mount, and exactly
which identity (human or machine) can read/write which slice of it. Verified
against the **live cluster** — actual policies, actual roles, actual identity
groups read via `bao policy read` / `bao read` — not just the design docs,
2026-08-04. Two places this diverges from documented *intent* are called out
explicitly below rather than papered over; see
[Live-state caveats](#live-state-caveats-design-vs-what-the-cluster-actually-has).

Complements two existing docs rather than replacing them:
- `docs/openbao-spiffe-access.md` — *how* a workload proves its identity to
  OpenBao at all (the SPIFFE/SPIRE trust chain). This doc assumes that
  mechanism and focuses on *what the resulting token can touch*.
- `docs/self-service-repos-github-app.md` — the design proposal that
  introduced this layered path layout (§"OpenBao KV — layered layout") and
  the root/admin split (§"root / admin split", **not yet live** — see
  caveats).

## The one-line version

- Every project's secrets live under one shared `kv` mount, isolated **by
  path**, not by mount — `kv/projects/<slug>/namespaces/<namespace>/*`.
- **Project owners** get the whole project subtree. **Namespace
  maintainers** (human or workload) get only their own namespace, plus one
  bucket shared across the project. **Namespace viewers get none** — by
  design, today (one live exception, see caveats).
- A grant made in the portal (`POST /access`) doesn't touch OpenBao at all
  directly — it changes a Keycloak group membership, which OpenBao's OIDC
  login already trusts via a pre-existing group-alias. The secret access
  "just works" on the user's *next OpenBao login*, not because teams-api or
  teams-operator pushed anything to OpenBao at grant time.

## KV path layout

```
kv/
  platform/                                    platform-management secrets
    keycloak-admin                             teams-operator-kc-admin's client secret
    github-app                                 the single legacy platform-wide GitHub App
    github-apps/<connection-id>                per-project GitHub App connections' keys
  projects/<slug>/                             project-management level (see caveats: currently unused, but owner-accessible)
    namespaces/
      shared/                                  secrets shared across every namespace in the project
      <namespace>/                             per-namespace app/workload secrets
```

`<slug>` is the project's sanitized name (`argocd_project_name(project)`);
`<namespace>` is the full `project-<slug>-<label>` namespace name. Namespaces
nest *under* the slug specifically so an owner-wide glob
(`kv/…/projects/<slug>/*`) is safe — namespaces are named
`project-<name>-<label>`, so a flat glob without the `/<slug>/` path
segment would also match a same-prefixed different project (e.g.
`project-foo-*` matching `project-foobar-*`). A literal path segment
boundary prevents that; ACL globbing in OpenBao respects `/`-delimited
prefixes.

It's a **kv-v2** mount, so every path above has two forms: `kv/data/...`
(read/write the actual secret value, versioned) and `kv/metadata/...` (list
keys, see version history, or delete *every* version outright — used for
teardown, not day-to-day use).

## Who's bound to which policy (verified live)

```
$ bao policy list
default  openbao-admin-policy  platform-operator-policy
project-demo-go-default-maintainer-policy   project-demo-go-owner-policy
project-demo-py-default-maintainer-policy   project-demo-py-owner-policy
teams-operator-admin-policy   root
```

| Policy | Bound to (identity-group-alias, or role) | How the binding happens |
|---|---|---|
| `openbao-admin-policy` | Keycloak group `argocd-admins` → OpenBao group `openbao-admins` | One-time bootstrap (`bootstrap/README.md`), not operator-managed. |
| `teams-operator-admin-policy` + `platform-operator-policy` | teams-operator's SPIFFE JWT-SVID → jwt auth role `teams-operator-admin` | One-time bootstrap (chicken-and-egg: the operator can't create its own first role). |
| `project-<slug>-owner-policy` | Keycloak group `project-<slug>-owner` | `ensure_openbao_project_access` (teams-operator, every poll cycle) — synced from the project's DB owners. |
| `<namespace>-maintainer-policy` | Keycloak group `<namespace>-maintainer` (humans) **and** jwt auth role `<namespace>` (workload SPIFFE IDs matching `spiffe://platform.local/ns/<namespace>/sa/*`) | `ensure_openbao_access` (teams-operator, every poll cycle) — the Keycloak group side is synced from DB namespace grants; the SPIFFE side needs no per-workload provisioning, any pod in that namespace qualifies. |
| *(namespace viewer)* | **No policy created.** | By design — see the docstring quoted in caveats below. |

## Access matrix (verified against live policy bodies)

| KV path | root | OpenBao admin | teams-operator | project owner | ns maintainer (human or workload) | ns viewer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `platform/*` | full | full¹ | read (`kv/data/platform/*`); CRUD on `.../github-apps/*` specifically | — | — | — |
| `projects/<slug>/` (management level, no namespace) | full | full¹ | — | CRUD | — | — |
| `projects/<slug>/namespaces/shared/*` | full | full¹ | — | CRUD | CRUD | —² |
| `projects/<slug>/namespaces/<ns>/*` | full | full¹ | delete-only, metadata path, teardown only (`_delete_kv_tree`) | CRUD | CRUD (that namespace only) | —² |

¹ **Not metadata-only** — see caveat 1, this is the live/design divergence.
² **Except one live orphaned exception** — see caveat 2.

A few things worth being explicit about, since the table alone doesn't show
them:

- **teams-operator never routinely reads or writes secret *values*.** Its
  `kv/metadata/projects/*` grant is `read, list, delete` — enough to
  enumerate what exists and wipe it wholesale on project/namespace deletion
  (`delete_openbao_access` → `_delete_kv_tree`), but there's no
  `kv/data/projects/*` grant on `teams-operator-admin-policy` at all. It
  cannot read a tenant's actual secret content.
- **A workload never gets project-owner-level access.** Tenant pods
  authenticate via the `<namespace>` jwt role, which only ever grants
  `<namespace>-maintainer-policy` — scoped to their own namespace plus the
  shared bucket, never the whole project subtree, even for a workload
  running in a namespace whose owner also happens to be logged into OpenBao
  elsewhere as a human.
- **The project-management level (`projects/<slug>/` with no `/namespaces/`
  segment) is currently unused** — nothing in `teams-api`/`teams-operator`
  writes there today, but it's already reachable by any project owner via
  the owner policy's glob, so it's available for a future "project-level
  secret, not tied to any one namespace" use case with no policy change
  needed.

## How a portal grant actually reaches OpenBao (end to end)

This is the part that's easy to assume is more automatic/direct than it
actually is — granting access in the UI **never calls OpenBao**. It changes
a database row and, transitively, a Keycloak group:

1. An owner/maintainer grants a teammate `maintainer` or `viewer` on a
   namespace: `POST /access` (`main.py`'s `grant_access`) — gated by
   `authz.require_namespace_manager`.
2. That writes a DB grant row (`store.set_grant`) and calls
   `_sync_group_membership`, which — since `KC_WRITES_ENABLED=false` live —
   is a no-op today; it exists as the pre-cutover write path, now dead.
3. The actual Keycloak write happens on **teams-operator's** next poll
   cycle (≤15s): `reconcile_keycloak` computes `desired_groups` straight
   from `/internal/access`'s snapshot of the DB (every namespace's
   viewer/maintainer lists, every project's owner list) and converges each
   Keycloak group's membership to match — adding/removing the user from
   `<namespace>-maintainer` or `<namespace>-viewer` as needed.
4. **Nothing OpenBao-side changes at grant time.** The OpenBao policy, jwt
   role, and identity-group-alias for that namespace were already created
   the first time the namespace existed (`ensure_openbao_access`, also
   every poll cycle, idempotent) — granting a user doesn't create new
   OpenBao objects, it just changes who's a member of a Keycloak group that
   an existing alias already points at.
5. The grant becomes *usable* the next time that user logs into OpenBao's
   UI via OIDC SSO: their Keycloak token's `groups` claim now includes
   `<namespace>-maintainer`, OpenBao's identity engine resolves that
   against the pre-existing external-group alias, and the token they end up
   holding carries `<namespace>-maintainer-policy`. A user already logged
   in when the grant lands doesn't get it until their next login (OpenBao
   tokens don't live-poll group membership).

Revocation is the same loop in reverse — remove the DB grant, the group
membership converges away on the operator's next cycle, and the *next*
OpenBao login for that user simply doesn't carry the policy anymore (an
already-issued token isn't proactively revoked, but its own TTL is short —
15m, max 1h, per the role's `token_ttl`/`token_max_ttl`).

## Live-state caveats (design vs. what the cluster actually has)

### Caveat 1: OpenBao admin is currently root-equivalent, not metadata-only

`docs/self-service-repos-github-app.md`'s "root / admin split" section
describes a target design where `openbao-admin-policy` is restricted to
`kv/metadata/*` (list/read only — see *what* exists, never secret values)
and loses `sys/policies/acl` write. **That split has not been applied.**
Verified live:

```
$ bao policy read openbao-admin-policy
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

Anyone in Keycloak's `argocd-admins` group is, today, fully root-equivalent
in OpenBao — full read of every secret value, not just metadata. This
matches the root `CLAUDE.md`'s "Current live state" note and is the
accurate current answer to "who can read secret values platform-wide": root
token holders *and* every `argocd-admins` member, not just root.

### Caveat 2: one orphaned viewer policy/group grants stale read access

Current code (`ensure_openbao_access`'s own docstring, `teams_operator.py`)
is explicit: *"No OpenBao viewer policy/alias is created: ns viewers get no
OpenBao access at all."* That's true for every namespace created under the
current code. But the live cluster still has one leftover object from an
earlier version of the operator, predating that change:

```
$ bao policy list | grep viewer
project-demo-go-default-viewer-policy

$ bao read identity/group/name/project-demo-go-default-viewer
policies    [project-demo-go-default-viewer-policy]
alias       ... mount_type:oidc name:project-demo-go-default-viewer
```

`project-demo-py-default` (created later) has no such policy — confirming
this is dated bootstrap-time drift on one specific namespace, not a
systemic issue. Nothing currently reconciles this away (the operator only
deletes OpenBao objects on namespace *deletion*, never prunes objects it no
longer creates). Practical effect: anyone currently in the
`project-demo-go-default-viewer` Keycloak group would get read-only access
to that one namespace's secrets on their next OpenBao login, contrary to
the documented "viewers get nothing" invariant. No group members are
currently mapped to it (`member_entity_ids` empty at time of writing), so
this is latent, not actively exploited — but it's live and would activate
the moment anyone with that Keycloak group membership logs into OpenBao.

**Decision (2026-08-04): left in place.** It's a single demo namespace with
no real tenant data behind it, and no group members are currently mapped to
it — not worth the live-cluster mutation today. Revisit before this
namespace ever holds real secrets, or clean it up as part of the planned
`kind delete` + recreate (a fresh bootstrap under current code never
creates this object in the first place).

## Where things live

| Concern | File |
|---|---|
| Per-namespace policy/role/alias reconcile (`ensure_openbao_access`) | `platform-idp/teams-management/teams-operator/teams_operator.py` |
| Project-wide owner policy/alias reconcile (`ensure_openbao_project_access`) | same file |
| Teardown (`delete_openbao_access`, `delete_openbao_project_access`, `_delete_kv_tree`) | same file |
| Keycloak group membership convergence (`reconcile_keycloak`) | same file |
| Policy/role template text actually written to OpenBao | `platform-infra/apps/developer-control/teams-operator/manifests/openbao-{policy,role}-templates/` |
| Portal grant endpoint (`POST`/`DELETE /access`) | `platform-idp/teams-management/teams-api/main.py` (`grant_access`/`revoke_access`) |
| One-time bootstrap of `openbao-admin-policy`, `teams-operator-admin-policy`, `platform-operator-policy` | `platform-infra/bootstrap/README.md`, `bootstrap/enable-openbao-jwt.sh` |
| The SPIFFE/SPIRE trust chain a workload uses to even get a JWT-SVID | `platform-infra/docs/openbao-spiffe-access.md` |
| The layered-KV design proposal (target state, incl. the not-yet-live root/admin split) | `platform-infra/docs/self-service-repos-github-app.md` |
