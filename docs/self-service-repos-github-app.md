# Self-service source repos + GitHub App repo access

Status: **design locked, implementation in progress** (2026-07-31).

This document is the design of record for a `teams-management` feature set that
makes a project's Argo CD **source repos** first-class and self-service, and
gives Argo CD access to **private** repos without anyone ever handling a key —
via a single platform **GitHub App**. It also re-lays-out OpenBao's KV mount into
explicit access **layers** and splits OpenBao **root** from **admin**.

It builds on, and should be read alongside:
- `docs/openbao-spiffe-access.md` — the SPIFFE/SPIRE → OpenBao workload path.
- `bootstrap/README.md` — the canonical bootstrap/ops runbook.

> **Update (2026-08-01): asks #1 and #2 below were reversed.** Source repos are
> now **optional at project creation** (a project can start empty; its card
> highlights that a repo must be registered before it can deploy, and the
> Source-repos section auto-expands when empty). The **global repository
> whitelist was removed entirely** (the `global_source_repos` table, the
> `/source-repos/global` endpoints, the `target=global` GitHub flow, and the
> create-form repo picker are all gone). Repos are added per-project only, via
> the GitHub connection flow. The multi-connection section at the bottom is the
> current design of record for how repos get connected.

## The five asks

1. ~~**Repo URLs are mandatory at project creation**~~ — reversed: optional (see above).
2. ~~**Admins curate a global repo whitelist**~~ — removed (see above).
3. **Project-managers may add ad-hoc repo refs** at creation if they need one
   that isn't whitelisted.
4. **Private-repo access for Argo CD is self-service via a GitHub App** — the PM
   clicks "Connect", authorizes in GitHub, and the repo is registered. No user
   ever handles a deploy key or token.
5. **The Source-repos section lists every repo** in the project's AppProject,
   annotated with its origin (global vs project) and connection status.

All source repos are on **GitHub** (a stated constraint — the GitHub App model is
GitHub-specific; a non-GitHub host would need a different path).

## Why a GitHub App (and not deploy keys)

Argo CD has **no native OpenBao integration for repository credentials** — it
reads repo creds only from k8s Secrets in the `argocd` namespace labeled
`argocd.argoproj.io/secret-type: repository` (per-repo) or `repo-creds`
(credential template, keyed by URL prefix). An earlier design stored a per-repo
SSH **deploy key** in OpenBao and had `teams-operator` materialize that Secret.
It was dropped in favour of a **GitHub App** because the App model is strictly
better here:

- **No user ever handles a key.** The PM clicks "Connect" → GitHub's
  install/authorize page → confirms. That's the whole interaction.
- **One secret, not N.** The only secret is the App's private key, held once at
  the platform layer (`kv/platform/github-app/`). Per repo you store only an
  `installation_id`, which is an identifier, not a secret.
- **Ephemeral derived tokens.** Argo CD mints its own ~1h GitHub *installation*
  tokens from the App key — aligned with this platform's short-lived,
  no-long-lived-per-tenant-key ethos, unlike a standing SSH key.
- **Central revocation, installation identity.** Uninstall the App and access is
  gone; access is not tied to any person's account.

Argo CD natively supports GitHub App repo creds via the `githubAppID`,
`githubAppInstallationID`, and `githubAppPrivateKey` fields on a `repository` /
`repo-creds` Secret. Public repos need no auth at all.

### The GitHub App flow end to end (Option B: teams-api never holds the App key)

The user picks the repos on GitHub; the *selection* is the input (no typing, no
dropdown). teams-api has no App key, so it can't enumerate the picked repos —
teams-operator (which holds the key) resolves them and reports them back.

```
user in teams-app          teams-api                 GitHub              teams-operator (holds App key) / Argo CD
  | "+ Add repos from GitHub"  |                        |                          |
  |-- GET /github/install-url --|  (target=project|global)                         |
  |    ?target=<id>            -|                        |                          |
  |<-- install URL + signed state                       |                          |
  |------------------- browser redirect ---------------->|                         |
  |                            |    user PICKS repositories on GitHub               |
  |<--- redirect GET /github/callback?installation_id&state ------------------------|
  |                            |- verify state, record PENDING (target,install_id)  |
  |                            |  (store.github_connections; NO enumeration here)   |
  |                            |                        |                          |
  |                            |<-- GET /internal/github-connections --------------|  (operator poll: top of reconcile)
  |                            |                        |<- App JWT -> inst token ->|
  |                            |                        |   /installation/repositories
  |                            |<-- POST /internal/github-connections/resolve ------|  (repos + install_id)
  |                            |-- add repos (source_repos+install_id | whitelist), |
  |                            |   clear pending                                    |
  |                            |                        |   reconcile_github_repo_creds:
  |                            |                        |   ONE repo-creds per account
  |                            |                        |   (App id+install+key from kv/platform)
  |                            |                        |   -> Argo CD mints ~1h tokens natively
```

One-time platform setup (bootstrap): register the GitHub App (`Contents: read`,
`Metadata: read`), set its **Setup URL (after installation)** — the redirect that
carries `installation_id`/`setup_action`/`state` — to teams-api's own ingress host
`https://teams-api.127.0.0.1.sslip.io:8443/github/callback` (teams-api serves at
its own host root, NOT under `/api` of the UI host `teams-ui.127.0.0.1.sslip.io`),
tick "Redirect on update", and store the App ID + private key at
`kv/platform/github-app/` (via `bootstrap/seed-github-app.sh`). The callback works
on the local cluster because the redirect is **browser-mediated** (the user's
browser resolves `127.0.0.1.sslip.io` to loopback); teams-api's own calls to
GitHub are outbound. teams-api env: `GITHUB_APP_SLUG`, `GITHUB_APP_STATE_SECRET`
(k8s Secret `teams-api-github-app`), `TEAMS_APP_URL=https://teams-ui.127.0.0.1.sslip.io:8443`.

## OpenBao KV — layered layout

Replaces today's flat `kv/<namespace>/*` per-namespace isolation with an explicit
project hierarchy:

```
kv/
  platform/                                   platform-management secrets
    github-app/                               the GitHub App private key + app id
  projects/<slug>/                            project-management secrets
    namespaces/
      shared/                                 secrets shared across the project's namespaces
      <namespace>/                            per-namespace app/workload secrets
```

`<slug>` is `argocd_project_name(project)` (the sanitized project name);
`<namespace>` is the full `project-<slug>-<label>` namespace name.

**Why namespaces nest under the slug:** it makes the owner-wide glob
`kv/…/projects/<slug>/*` *safe*. Namespaces are named `project-<name>-<label>`, so
a flat glob like `kv/project-foo-*` would also match `project-foobar-*` — a real
cross-project leak. A literal `/<slug>/` path segment prevents that (segment
boundaries are respected by ACL globbing).

### Access matrix

| path (`kv/…`) | root | admin | teams-operator | project owner | ns maintainer | ns viewer |
|---|:---:|:---:|:---:|:---:|:---:|:---:|
| `platform/*` | full | metadata only | read | — | — | — |
| `projects/<slug>/` (top) | full | metadata only | — | CRUD | — | — |
| `projects/<slug>/namespaces/shared/*` | full | metadata only | — | CRUD | CRUD | — |
| `projects/<slug>/namespaces/<ns>/*` | full | metadata only | — | CRUD | CRUD (that ns) | — |

- **admin** gets `kv/metadata/*` `list,read` everywhere and **no `kv/data` read
  anywhere** — they see *what* secrets exist, never their values.
- **ns viewer** gets **no OpenBao access** (the `<ns>-viewer` group still exists,
  used only for k8s and Argo CD RBAC).
- **project owner** access is a single glob `kv/{data,metadata}/projects/<slug>/*`
  — it covers shared + every namespace, including ones added later.
- Tenant **workloads** authenticate per-namespace via SPIFFE and carry the ns
  maintainer policy (they must write their own secrets), unchanged in spirit.

## OpenBao authorization model — root / admin split

Today `openbao-admin-policy` is `path "*"` (superuser) bound to the
`argocd-admins` Keycloak group — i.e. admin == root. This splits them:

- **root** — the unseal-derived root token (`bootstrap/init-keys.json`).
  **Break-glass only**, never bound to any OIDC group, used only for bootstrap
  and recovery.
- **admin** (`argocd-admins`) — *operates* OpenBao: manage secret **mounts**,
  **auth methods**, and **identity** (groups/aliases), plus `kv/metadata/*`
  `list,read`. **No `sys/policies/acl` write. No `kv/data` read.**
- **teams-operator** — the **only** author of `project-*` ACL policies, rendered
  from git-reviewed templates; reads `kv/platform/*` (for the App key).
- **project owners / PMs** — never write policies. They express **intent** via
  teams-api (ownership, per-namespace grants, project-secret access); the
  operator reconciles that into fixed, path-scoped policies + group-aliases.

### Two honest residuals (accepted)

1. **Admin can still self-escalate to secret data** — holding `identity/*` (and
   `sys/auth`/`sys/mounts`) write, an admin can attach an *existing*
   data-granting policy (e.g. a namespace maintainer policy) to a group and add
   themselves. Removing policy-write + data-read stops *casual* reads and stops
   *inventing* new access, but is not a cryptographic wall. Accepted: admins are
   trusted operators and every action is in the OpenBao audit log.
2. **Delegated scoped policy-authoring is impossible in OpenBao OSS** — ACL
   governs the policy *name* endpoint (`sys/policies/acl/<name>`), not the paths
   *inside* the policy body, so a PM allowed to write `project-<slug>-*` policies
   could author one granting `kv/data/*`. This is why PMs never author policies;
   they only express intent and the operator owns the (fixed-path) templates.

## Component changes

### platform-infra (do first — a full cluster rebuild is planned)

- **Root/admin split** in `bootstrap/enable-oidc-sso.sh` + `bootstrap/README.md`:
  rewrite `openbao-admin-policy` to the restricted admin set above (drop
  `path "*"`).
- **Operator policy templates** in
  `apps/developer-control/teams-operator/manifests/openbao-policy-templates/`:
  - `project-owner.hcl` *(new)* → CRUD `kv/{data,metadata}/projects/<slug>/*`
  - `project-maintainer.hcl` *(repoint)* → CRUD `…/namespaces/<ns>/*` **and**
    `…/namespaces/shared/*`
  - `project-viewer.hcl` → **retired for OpenBao** (ns viewer has no OpenBao
    access; group kept for k8s/Argo RBAC)
- **Operator bootstrap grant** (`bootstrap/enable-openbao-jwt.sh`): change the
  cleanup glob `kv/metadata/project-*` → `kv/metadata/projects/*`; keep
  `sys/policies/acl/project-*`, `auth/jwt/role/project-*`,
  `identity/group/name/project-*`, `identity/group-alias`. Also create
  `platform-operator-policy` (read `kv/{data,metadata}/platform/*`) here by root
  — NOT operator-rendered, since its name is outside the operator's `project-*`
  self-management glob so the operator can't widen its own platform access — and
  attach it to the `teams-operator-admin` jwt role's `token_policies`.
- **`kv/platform/github-app/`** seeded once with the App id + private key.

### teams-operator

- **Layered KV** in `ensure_openbao_access` / `delete_openbao_access` /
  `_delete_kv_tree`: new path hierarchy; add a `project-<slug>-owner` policy + a
  **new `project-<slug>-owner` Keycloak group** + alias; sync DB owners into it;
  stop creating the OpenBao viewer policy/alias.
- **AppProject union** in `ensure_argocd_appproject`: merge **global ∪
  per-project** repos; **fold the global set into the `_last_synced` state key**
  or a whitelist change silently leaves every AppProject stale.
- **GitHub App repo credentials**: for each connected repo (teams-api's
  `repo_installations` in `/internal/teams`), materialize one Argo CD `repository`
  Secret in the `argocd` namespace (`argocd.argoproj.io/secret-type: repository`,
  label `teams-operator/project=<slug>`) with `githubAppID` +
  `githubAppInstallationID` + `githubAppPrivateKey`, reading the App id + key from
  OpenBao `kv/platform/github-app` (keys **`app_id`** and **`private_key`**). One
  Secret per repo (name `<slug>-repo-<sha1(url)[:10]>`), pruned when a repo is
  disconnected/removed, and all deleted by label on project deletion.
  `ensure_argocd_repo_credentials` / `delete_argocd_repo_credentials`; the connected
  set is folded into the reconcile `state_key`.

### teams-api

- **`ProjectCreate`** gains required `source_repos: List[str]` (≥1, URL-validated),
  inserted in the same transaction as the project.
- **Global whitelist**: `global_source_repos` table; `GET /source-repos/global`
  (any authed reader) + `POST`/`DELETE` (`require_admin`).
- **GitHub App**: `GET /github/install-url` (signed `state`) and
  `GET /github/callback` (validate state, record `installation_id` metadata).
- **Source-repos response** enriched: `List[str]` → objects `{url, origin, status}`.
- Never stores any secret material.

### teams-app

- Project-create form: mandatory repo list (multi-select from whitelist +
  free-text add).
- Admin-only global-whitelist management surface (gated on `me.is_admin`).
- Source-repos section: per-repo **"Connect GitHub"** button + origin/status
  badges.

## Breaking changes

1. `ProjectCreate` now requires `source_repos` — breaks callers sending `{name}`
   (API tests; the legacy `teams-cli` already targets a stale `/teams` route).
2. `GET …/source-repos` response shape changes (`List[str]` → objects) — UI moves
   in lockstep.
3. **OpenBao admin is no longer root** — rewrites the CLAUDE.md/README narrative;
   existing admins lose data-read + policy-write.
4. **KV paths move** (`kv/<ns>/*` → `kv/projects/<slug>/namespaces/<ns>/*`) — any
   workload/doc hardcoding the old path breaks; `docs/openbao-spiffe-access.md`
   and the teams-app "Secrets" deep-link update. No data migration: no live
   projects + a rebuild is planned.
5. **One new Keycloak group per project** (`project-<slug>-owner`).
6. Global-whitelist state-key handling (above) or AppProjects go stale silently.

Everything else (existing source-repo CRUD, k8s/Argo RBAC, namespace flows) is
additive.

## Multi-connection: per-project GitHub Apps (extension, 2026-08-01)

The base design above assumes a **single** platform GitHub App (`kv/platform/
github-app`, one `GITHUB_APP_SLUG`). This extension lets a project connect repos
through **its own GitHub App**, chosen from a picker, and lets a project owner /
manager **register a new App** without anyone handling a key.

**Decisions (locked):** connections are **per-project** (a connection belongs to
the project that registered it); a **project owner/PM** may register one; the
registration mechanism is GitHub's **App-Manifest creation flow** (GitHub returns
the key programmatically). The single platform App is retained only for the
**global whitelist** (`target=global`, admin).

### Concept

A **connection** = a registered GitHub App. `github_app_connections` (teams-api
DB, per-project) holds non-secret metadata `{id, project_id, name, slug, app_id,
status, created_by}`; the App **private key** lives in OpenBao at
`kv/platform/github-apps/<connection-id>`. `project_source_repos` gains
`connection_id` (which App minted a connected repo's installation; `''` = the
legacy platform App).

### Registration flow (teams-api never holds the key)

```
PM in teams-app         teams-api                      GitHub                 teams-operator (holds vault write)
 | "Register new connection" |                            |                            |
 |-- GET /github/register-url?project_id -|               |                            |
 |<-- {action_url, manifest, connection_id}  (row: pending)|                           |
 |--- auto-POST form: settings/apps/new?state -----------> | user picks account, Creates App
 |<-- redirect GET /github/manifest-callback?code&state ---|                           |
 |    verify state -> record registration(code)            |                           |
 |                            |<-- GET /internal/github-registrations --------------- |  (operator poll)
 |                            |                            |<- POST /app-manifests/{code}/conversions
 |                            |                            |   -> {id, slug, name, pem}|
 |                            |                            |   write pem -> OpenBao kv/platform/github-apps/<id>
 |                            |<-- POST /internal/github-registrations/resolve ------- |  {app_id, slug, name}
 |                            |    connection -> 'ready'   |                           |
```

The one-time manifest `code` (the conversion response carries the private key) is
exchanged **by the operator**, the component that owns OpenBao writes — teams-api
only ever holds the `code`, never the key, preserving the base design's Option-B
invariant. The manifest pins least privilege (`Contents: read`, `Metadata: read`).

Adding repos then reuses the existing install flow, now per connection:
`GET /github/install-url?target=<project>&connection_id=<id>` → that connection's
App install page → `/github/callback` records `(target, installation_id,
connection_id)` → operator resolves repos with **that connection's** key.

### Credential materialization — per-repo, to avoid prefix collisions

Argo CD matches `repo-creds` templates by **longest URL prefix**. With per-project
connections, two projects can each register an App reaching the same GitHub
account, producing two templates claiming the same prefix — Argo CD can't tell
which App's token to mint. So connection-bound repos get **per-repo `repository`
Secrets** (exact-URL match beats any prefix template), one per connected repo,
carrying that connection's `githubAppID`/key
(`ensure_connection_repo_credentials`, label `teams-operator/github-conn-repo`).
The legacy account-level `repo-creds` path (`reconcile_github_repo_creds`) is kept
only for connection-less repos + the global whitelist (the platform App).

### Component surface

- **teams-api**: `github_app_connections` + `github_app_registrations` tables;
  `GET /projects/{id}/github/connections`, `GET /github/register-url`,
  `GET /github/manifest-callback` (public), `GET /github/install-url` gains
  `connection_id`; internal `GET /internal/github-registrations` +
  `/resolve`; `/internal/github-connections(/resolve)` and `/internal/teams`
  carry `connection_id` + per-project `github_connections`. New env
  `TEAMS_API_PUBLIC_URL` (manifest redirect target).
- **teams-operator**: `resolve_github_registrations` (+ `_exchange_manifest_code`,
  `_store_connection_app_key`); `_github_app_creds(connection_id)`;
  `ensure_connection_repo_credentials`.
- **teams-app**: "Add repos from GitHub" opens a connection **picker** (choose a
  ready connection, or "Register new connection" → auto-submitting manifest form).
- **OpenBao**: `platform-operator-policy` gains create/update on
  `kv/data/platform/github-apps/*` (scoped tighter than the read-only
  `platform/*` glob) — see `bootstrap/enable-openbao-jwt.sh`.

### Known follow-ups

- **Orphaned connection keys**: deleting a project cascades its
  `github_app_connections` rows (DB) but leaves the App key at
  `kv/platform/github-apps/<id>` in OpenBao — a teardown step should prune it
  (the operator now holds delete on that subtree).
- **Global whitelist** still uses the single platform App; unifying it onto the
  connection model is deferred.
