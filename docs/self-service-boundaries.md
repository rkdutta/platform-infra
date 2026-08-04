# Self-service boundaries: who can create what, and what actually enforces it

This documents three platform invariants that are easy to state informally but
are enforced by different mechanisms — some by the platform, some by GitHub,
one only by convention (currently, not by a technical control). Written
2026-08-04 after verifying each claim against the live cluster and the current
`platform-idp` source, not just the design docs.

## 1. Project managers can only connect GitHub repos they have access to

**Enforced by GitHub, not by the platform.** `teams-api` never holds a GitHub
user token and never checks GitHub-side permissions itself — it only learns
whatever GitHub hands back (an `installation_id`). The actual repo-visibility
check happens entirely on GitHub's own install/authorize page: a user can only
select orgs/repos they already have admin access to there.

What the platform *does* enforce is a narrower thing — **who on the platform**
may even start a connection attempt:

- `GET /github/register-url` (create a new GitHub App) and
  `GET /github/install-url` (add repos via an existing App connection) are
  both gated by `authz.require_project_owner` — only an owner of the target
  project can initiate either flow.
  (`platform-idp/teams-management/teams-api/main.py:1069`, `:1115`)

So: "can't add a repo without GitHub access" is correct, but read it as *two*
independent checks — project ownership (platform-side) and repo access
(GitHub-side) — not one. See `docs/self-service-repos-github-app.md` for the
full connection flow (App-Manifest creation → install → callback →
`teams-operator` resolves the installation and writes the App key to OpenBao;
`teams-api` never exchanges the manifest code and never holds key material).

## 2. Every Argo CD Application must belong to a real, governed project

**True, and actively enforced by two Gatekeeper constraints** (verified live:
both `ConstraintTemplate`s present, both constraints `enforcementAction: deny`,
`status.totalViolations: 0` at time of writing):

- **`restrict-appproject-writes`** — only `teams-operator`'s ServiceAccount
  (`system:serviceaccount:engineering-platform:teams-operator`), or break-glass
  `system:masters`, may create/update an `AppProject`. Nobody else — not a
  project owner, not the Argo CD UI/API — can create one directly. The
  built-in `default` AppProject is exempted by name (Argo's own install, not
  operator-managed).
  (`apps/security/tenant-guardrails/manifests/restrict-appproject-writes-{template,constraint}.yaml`)
- **`require-application-project`** — an `Application` may not target project
  `default` (or leave `spec.project` unset, which resolves to `default`).
  `system:masters` and the `root` app-of-apps are exempted (root legitimately
  bootstraps into `default` and must stay reconcilable by Argo's own
  controller, whose ServiceAccount isn't `system:masters`).
  (`apps/security/tenant-guardrails/manifests/require-application-project-{template,constraint}.yaml`)

Together: since only `teams-operator` can create an `AppProject`, and every
`Application` must target a non-`default` project, every deployed workload is
necessarily routed through a project that originated from a `teams-api`
project record. This is also how source-repo authorization is transitively
enforced — an Application's project has a Gatekeeper-fixed `sourceRepos` list,
so you can't "sneak a repo in" by pointing at the permissive default project.

Live check used to confirm enforcement (not just declared in git):

```bash
kubectl get constrainttemplates k8srequireapplicationproject k8srestrictappprojectwrites
kubectl get k8srequireapplicationproject require-application-project -o jsonpath='{.status.totalViolations}'
kubectl get k8srestrictappprojectwrites restrict-appproject-writes -o jsonpath='{.status.totalViolations}'
```

## 3. Project creation is "only via teams-ui" — **not accurate as a technical claim**

`POST /projects` is gated by `auth.require_admin_or_project_manager` — a check
on the caller's **Keycloak realm role** (`admin` or `project-manager`) only.
(`platform-idp/teams-management/teams-api/auth.py:335`,
`main.py:781` for the route wiring.)

Nothing ties this to teams-app specifically:

- CORS is wide open — `allow_origins=["*"]`
  (`platform-idp/teams-management/teams-api/main.py:143`).
- There is no client-identity, User-Agent, or Origin check anywhere in
  `main.py`.
- Any bearer token holding the right realm role can call it from curl,
  Postman, or a script.

**In practice teams-ui is the only *working* client today, but that's
incidental breakage, not a designed restriction.** `teams-cli` already ships
`create` / `list` / `get` / `delete` commands
(`platform-idp/teams-management/teams-cli/teams_cli.py:157` on) — but they
call `POST /teams`, `GET /teams`, `GET /teams/{id}`, `DELETE /teams/{id}`,
which are **pre-rename endpoints that no longer exist**. `main.py` has no
`/teams` route at all anymore — only `/projects*`. This is leftover from the
Teams→Projects rename (see the root `CLAUDE.md` gotcha on `team_*` naming),
not something anyone intentionally disabled. Every CLI project-lifecycle
command will 404 against the live API until it's repointed at `/projects`.

If "teams-ui only" is meant to become an actual invariant (not just today's
accident), it needs a real control — e.g. checking `azp`/`aud` on the token
for a UI-specific client, or fixing the CLI and deciding project creation
*should* be a supported non-UI path instead.

## Where things live

| Concern | File |
|---|---|
| GitHub connection auth (project-owner gate) | `platform-idp/teams-management/teams-api/main.py:1069`, `:1115` |
| GitHub App flow detail | `platform-infra/docs/self-service-repos-github-app.md` |
| Project creation auth | `platform-idp/teams-management/teams-api/auth.py:335`, `main.py:781` |
| CORS config | `platform-idp/teams-management/teams-api/main.py:143` |
| Broken CLI project commands | `platform-idp/teams-management/teams-cli/teams_cli.py:157`–`~210`, `:462`–`503` |
| Application → project admission control | `platform-infra/apps/security/tenant-guardrails/manifests/require-application-project-{template,constraint}.yaml` |
| AppProject write restriction | `platform-infra/apps/security/tenant-guardrails/manifests/restrict-appproject-writes-{template,constraint}.yaml` |
