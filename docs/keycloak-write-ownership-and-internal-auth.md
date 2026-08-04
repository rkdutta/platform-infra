# Keycloak Write Ownership & `/internal` Auth — Steady State

This documents the **final** architecture after the migration that moved all
Keycloak *writes* out of the user-facing `teams-api` and into the attested
`teams-operator` reconciler, and that switched `teams-api`'s `/internal/*`
control-plane endpoints from a static Keycloak client-credentials secret to
`teams-operator`'s SPIFFE JWT-SVID.

It describes the end state only — not the transient dual-write/dual-accept
phases used to get there safely. If you need the migration mechanics (the
flags and the order they were flipped), see the "Migration history" section at
the bottom and the git history of the files listed under "Where things live".

## The one-line version

- **`teams-api` is the only writer of the platform database. It never writes
  Keycloak** — it only *reads* the realm (user/group lookups for the
  assignment picker and validation), using a read-only service-account client.
- **`teams-operator` is the sole writer of Keycloak realm state.** It
  continuously reconciles the k8s-access groups, the per-project owner groups,
  and the `project-manager` realm role from the platform DB — the same
  reconcile loop that already owns namespaces, RBAC, quotas, and OpenBao.
- **`teams-operator` authenticates to `teams-api`'s `/internal/*` endpoints
  with its SPIFFE JWT-SVID** (audience `teams-api`), not a Keycloak token and
  not a static secret. There is no `teams-operator-sa` Keycloak client and no
  `teams-operator-keycloak-secret` anymore.

## Why it's shaped this way

`teams-api` is the internet-facing, user-authenticated surface. Giving it
Keycloak *write* credentials meant a compromise of that surface was a
compromise of the identity provider's realm — it could mint groups, roles, and
group memberships that grant real cluster access. Moving every Keycloak write
into `teams-operator` shrinks the blast radius: the operator is an internal,
non-user-facing controller whose only inputs are (a) the platform DB it polls
and (b) its own SPIFFE identity. `teams-api` keeps *read-only* realm access,
which is all the UI's assignment picker needs.

The `/internal` auth change follows the same principle. The operator used to
prove "I am the operator" with a shared secret (`teams-operator-sa`'s
client-credentials). A shared secret is a static credential that can leak, has
to be rotated, and is honored by anyone who holds it. Its SVID is a
short-lived, non-exportable, cryptographically-attested identity issued by
SPIRE off the pod's own workload identity — the same trust root the operator
already uses for OpenBao. One trust model, no static secrets.

## Steady-state components

### `teams-api` (reads only)

- Writes: **the platform DB only** (`store.py`). Project records, owners,
  project-managers, GitHub connections, etc.
- Keycloak: **read-only**. Client `teams-api-sa`, scoped to
  `view-realm, view-users, query-users, query-groups` — enough to list/resolve
  users and read group/role membership for the UI's picker and for validating
  an assignment, and nothing more. It holds no realm-*management* write role.
- `/internal/*`: validates the caller's **SPIRE JWT-SVID** against SPIRE's
  JWKS. It pins the issuer, the `teams-api` audience, and the exact operator
  SPIFFE ID. A Keycloak token presented here is refused — its signing key is
  not in SPIRE's JWKS. (See the auth matrix below.)

Relevant env (`apps/developer-control/teams-api/manifests/deployment.yaml`):

| Var | Value | Meaning |
|---|---|---|
| `INTERNAL_AUTH_MODE` | `svid` | `/internal/*` validates the operator's JWT-SVID (not a Keycloak token). |
| `SPIRE_JWKS_URL` | `https://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local/keys` | Where the SVID signing keys are fetched. |
| `SPIRE_ISSUER` | `https://oidc-discovery.platform.local` | The `iss` claim on the SVID (NOT the fetch URL above). |
| `OPERATOR_SPIFFE_ID` | `spiffe://platform.local/ns/engineering-platform/sa/teams-operator` | The only `sub` accepted on `/internal/*`. |
| `KC_ADMIN_CLIENT_ID` | `teams-api-sa` | The **read-only** directory client. |

`KC_WRITES_ENABLED` still exists in `teams-api` (`main.py`) and is still an
explicit env on the Deployment — pinned to `"false"`. It was **not** removed;
the write methods it gates (`keycloak_admin.py`'s `ensure_group`,
`delete_group`, `assign_realm_role`, `remove_realm_role`,
`add_user_to_group`, `remove_user_from_group`) are all still present in code,
just dead in practice while the flag is off. Kept as the documented rollback
lever back to dual-write, same as `INTERNAL_AUTH_MODE`/`TEAMS_API_AUTH`/
`KC_RECONCILE_ENABLED` below.

### `teams-operator` (sole Keycloak writer, SVID caller)

- Reconciles Keycloak realm state from the DB in `reconcile_keycloak`
  (`teams_operator.py`): the `{namespace}-viewer` / `{namespace}-maintainer`
  k8s-access groups, the `project-<slug>-owner` groups, and the
  `project-manager` realm role + its memberships. Idempotent, every poll cycle.
- Uses a dedicated admin client, `teams-operator-kc-admin`, whose secret is
  delivered **from OpenBao over the operator's SPIFFE identity**
  (`kv/platform/keycloak-admin`) — not a static k8s Secret.
- Calls `teams-api`'s `/internal/*` by presenting its **teams-api-audience
  JWT-SVID**, written by its `spiffe-helper` sidecar. No Keycloak token, no
  static secret.

Relevant env (`apps/developer-control/teams-operator/manifests/deployment.yaml`):

| Var | Value | Meaning |
|---|---|---|
| `TEAMS_API_AUTH` | `svid` | Present the teams-api-audience SVID to `/internal/*`. |
| `TEAMS_API_SVID_PATH` | `/operator-shared/teams-api-jwt` | Where the sidecar writes that SVID. |
| `KC_RECONCILE_ENABLED` | `true` | The operator is the Keycloak writer. |
| `KEYCLOAK_ADMIN_CLIENT_ID` | `teams-operator-kc-admin` | The realm-write client. |
| `KEYCLOAK_ADMIN_OPENBAO_PATH` | `kv/data/platform/keycloak-admin` | Where its secret is read from, over SPIFFE. |

### The operator's two SVIDs

The operator's `spiffe-helper` sidecar uses a **dedicated** config,
`operator-spiffe-helper.conf` (not the per-tenant `spiffe-helper.conf` the
operator copies into tenant namespaces), because the operator needs **two**
JWT-SVIDs with different audiences:

| Audience | File | Used for |
|---|---|---|
| `openbao` | `/operator-shared/spiffe-jwt` | Logging in to OpenBao (privileged `teams-operator-admin` role). |
| `teams-api` | `/operator-shared/teams-api-jwt` | Authenticating to `teams-api`'s `/internal/*`. |

A tenant workload must never be handed a `teams-api` credential, which is
exactly why the tenant template stays `openbao`-audience-only and the operator
gets its own config file.

## The `/internal/*` auth matrix (verified)

With `INTERNAL_AUTH_MODE=svid`, calling `/internal/teams` yields:

| Presented credential | Result |
|---|---|
| No bearer | `401` "Missing operator SVID" |
| Malformed token | `401` "Invalid operator SVID" |
| Operator JWT-SVID (`aud=teams-api`, correct `sub`/`iss`) | `200` |
| Keycloak `teams-operator-sa` token | `403` "no matching SPIRE key" |

The last row is the point of the change: even a validly-minted Keycloak token
is refused, because `teams-api` only trusts SPIRE's JWKS on this path. This is
a clean cut, not a dual-accept.

## What was retired

- The **`teams-operator-sa` Keycloak client** — removed from both realm copies
  (`apps/security/keycloak/application.yaml` inline import **and**
  `teams-realm.json`), along with its `service-account-teams-operator-sa` user.
- The **`teams-operator-keycloak-secret`** k8s Secret manifest
  (`keycloak-operator-secret.yaml`) and its entry in the operator's
  `kustomization.yaml`.
- The **`OPERATOR_CLIENT_SECRET`** env on the operator Deployment.

> Note: Keycloak imports the realm only on first startup, so the
> `teams-operator-sa` client lingers in a **running** Keycloak until the realm
> is re-imported (e.g. the planned `kind` recreate). It is inert — nothing
> presents its token, and `teams-api` refuses it anyway (the `403` above). To
> remove it from a live realm immediately, delete the client via the Keycloak
> admin API/console; otherwise it disappears on the next fresh import.

## Where things live

| Path | Role |
|---|---|
| `platform-idp/teams-management/teams-api/auth.py` | `/internal` SVID validation (`_validate_operator_svid`, `require_operator`); `INTERNAL_AUTH_MODE` handling. |
| `platform-idp/teams-management/teams-api/main.py` | Read-only Keycloak lookups; `/internal/*` routes; DB-only writes. |
| `platform-idp/teams-management/teams-api/store.py` | The platform DB (incl. `project_managers`). |
| `platform-idp/teams-management/teams-operator/teams_operator.py` | `reconcile_keycloak` (sole writer); SVID-based `/internal` calls. |
| `apps/developer-control/teams-api/manifests/deployment.yaml` | teams-api env (svid mode, read-only client). |
| `apps/developer-control/teams-operator/manifests/deployment.yaml` | operator env (svid mode, KC reconcile on); the two-SVID sidecar. |
| `apps/developer-control/teams-operator/manifests/openbao-agentconfig-templates/operator-spiffe-helper.conf` | The operator's dedicated two-audience sidecar config. |
| `apps/security/keycloak/{application.yaml,teams-realm.json}` | The realm: `teams-api-sa` (read-only), `teams-operator-kc-admin` (writer). **Two copies, kept in sync by hand.** |

## Migration history (for context only)

The cutover was done as a flag-gated, reversible sequence so the platform kept
working at every step:

1. **Flip #1** — operator started writing Keycloak (`KC_RECONCILE_ENABLED=true`)
   while `teams-api` still wrote too. Dual-write is safe because both writers
   are idempotent against the same desired state; while it was on, `teams-api`
   covered any operator lapse and vice-versa.
2. **Flip #2** — `teams-api` stopped writing Keycloak (`KC_WRITES_ENABLED=false`),
   leaving the operator as sole writer.
3. **A1** — `/internal` auth switched to SVID on both sides
   (`INTERNAL_AUTH_MODE=svid` + `TEAMS_API_AUTH=svid`), a clean cut with no
   dual-accept.
4. **Retirement** — `teams-operator-sa` (client, secret, env) removed, since
   nothing honored or presented it anymore.

`KC_WRITES_ENABLED`, `KC_RECONCILE_ENABLED`, `INTERNAL_AUTH_MODE`, and
`TEAMS_API_AUTH` all remain as explicit env in the manifests at their
steady-state values — none were deleted from code or manifests. They still
gate the code paths; pinning them explicitly documents intent and keeps a
rollback lever if ever needed.
