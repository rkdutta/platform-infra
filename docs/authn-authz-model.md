# teams-api authentication & authorization model

How each caller (teams-ui, teams-cli, teams-operator) proves who it is to
teams-api, and how every route is actually protected end to end. Verified
against the live `platform-idp` source and the deployed manifests,
2026-08-04. Complements `docs/keycloak-write-ownership-and-internal-auth.md`
(which covers the SVID cutover history in more depth) and
`docs/self-service-boundaries.md` (specific ownership-check call sites for
project/GitHub-connection endpoints).

## The one-line version

- **teams-ui and teams-cli authenticate as a human**, via Keycloak OIDC —
  standard bearer access tokens, validated against Keycloak's JWKS.
- **teams-operator authenticates as a workload, not a human** — a SPIRE
  JWT-SVID, validated against SPIRE's own (separate) JWKS. It never holds a
  Keycloak credential for this path.
- **Authentication is enforced globally**, as a FastAPI app-level dependency
  — every route is protected by default; the exceptions are an explicit,
  small allowlist, each with its own justification.
- **Authorization is layered on top per-route**, resolved live against the
  database on every request (project ownership + per-namespace grants), never
  trusted from token claims — so a permission change takes effect on the
  caller's very next request.

## Two callers, two trust roots

| Caller | Identity proof | Validated against | Config |
|---|---|---|---|
| teams-ui (browser) | Keycloak access token, client `teams-ui` (public, no secret) | Keycloak JWKS (`OIDC_JWKS_URL`) | `auth.py` `_decode` |
| teams-cli | Keycloak access token, client `teams-cli`, same realm | Same Keycloak JWKS | `auth.py` `_decode` |
| teams-operator (`/internal/*` only) | SPIRE JWT-SVID, audience `teams-api` | SPIRE's JWKS (`SPIRE_JWKS_URL`) — a *different* key set from Keycloak's | `auth.py` `_validate_operator_svid` |

## teams-ui → teams-api

`teams-app` is a **public** Keycloak client (`clientId: "teams-ui"`,
`publicClient: true` — confirmed in `teams-realm.json`; no client secret,
appropriate for code running in a browser). Login is the standard OIDC
Authorization Code flow via `keycloak-angular`/`keycloak-js`
(`teams-app/src/app/services/auth.service.ts`); the SPA holds the resulting
access token in memory.

Every outgoing HTTP call to teams-api gets the token attached by
`AuthInterceptor` (`teams-app/src/app/interceptors/auth.interceptor.ts`):

```ts
const authReq = req.clone({ setHeaders: { Authorization: `Bearer ${token}` } });
```

teams-api validates it in `auth.authenticate()` → `_decode()`: RS256 signature
against Keycloak's JWKS, `iss` pinned to `OIDC_ISSUER`, `exp` required.
**`aud` is deliberately not checked** — Keycloak's default access-token
audience is `"account"`, not this API, so signature + issuer + expiry are
what actually gate access. Verified claims land on `request.state.claims`;
`sub` (the stable Keycloak user id) — not the mutable `preferred_username` —
is the key every ownership/grant row in the DB is stored against.

## teams-cli → teams-api

Same validation path as teams-ui — same realm, same JWKS, same `_decode()`.
The CLI has its own Keycloak client (`teams-cli`) and gets a token via a
loopback OAuth2 Authorization Code + PKCE flow (`teams_cli.py`'s `login`
command). From teams-api's point of view a CLI-presented token and a
browser-presented token are indistinguishable — both are "an authenticated
realm user," and authorization is resolved the same way for both (see
below). There is no CLI-specific carve-out or elevated trust.

## teams-operator → teams-api (`/internal/*` only)

Not Keycloak. teams-operator's `spiffe-helper` sidecar mints a **dedicated**
`teams-api`-audience JWT-SVID (distinct from the `openbao`-audience SVID it
also holds — see `docs/keycloak-write-ownership-and-internal-auth.md` §"The
operator's two SVIDs") and writes it to `/operator-shared/teams-api-jwt`. The
operator presents that as the bearer on every `/internal/*` call.

teams-api validates it in `_validate_operator_svid()` against **SPIRE's**
JWKS (`SPIRE_JWKS_URL`) — a completely separate trust root from Keycloak's —
pinning:
- `iss` = `SPIRE_ISSUER` (`https://oidc-discovery.platform.local`)
- `aud` = `TEAMS_API_SVID_AUDIENCE` (`teams-api`)
- `sub` = the *exact* `OPERATOR_SPIFFE_ID`
  (`spiffe://platform.local/ns/engineering-platform/sa/teams-operator`) —
  not just "any valid SVID from this trust domain"

Confirmed live in both deployment manifests: `INTERNAL_AUTH_MODE=svid` on
teams-api, `TEAMS_API_AUTH=svid` on teams-operator. A legacy `"keycloak"`
fallback mode still exists in code (client-credentials via a
`teams-operator-sa` Keycloak client, checked by `azp`) but is not what's
running — see the linked doc for the full retirement story.

## Authentication is enforced globally, not per-route

`authenticate` and `require_read` are wired directly on the `FastAPI(...)`
constructor's `dependencies=`, not as a per-route `Depends()`:

```python
app = FastAPI(..., dependencies=[Depends(authenticate), Depends(require_read)])
```

That means they run on **every** route before its body executes, unless the
path is in the explicit `PUBLIC_PATHS` allowlist:

| Public path | Why |
|---|---|
| `/`, `/health`, `/docs`, `/redoc`, `/openapi.json` | Probes / API docs — no user data. |
| `/github/callback`, `/github/manifest-callback` | GitHub redirects the user's *browser* here with no way to carry a bearer token — see below. |
| (any `OPTIONS`) | CORS preflight carries no `Authorization` header by spec. |

The two GitHub callback routes aren't actually unauthenticated in a
meaningful sense — they verify an HMAC-signed `state` blob
(`GITHUB_APP_STATE_SECRET`) that teams-api itself minted earlier, at
`/github/register-url` or `/github/install-url`, both of which **are**
gated by `authz.require_project_owner`. Trust is anchored back to an
authenticated, ownership-checked call either way; the callback just can't
re-present a bearer token because GitHub's redirect can't carry one.

Missing/malformed/expired bearer token on anything else → `401` before any
handler code runs. `/internal/*` is deliberately **not** in the public list
— per `_is_public`'s own docstring, those endpoints return unscoped,
cluster-wide data, so they need the same bearer-token bar as everything else,
*plus* the additional operator-identity check below.

## Authorization: resolved live from the DB, not from the token

`auth.py` only answers "who is calling" — `authz.py` answers "what may they
do," and (with one deliberate exception) does it by reading the database on
every single request rather than trusting anything baked into the token:

- **admin** — the one authority left as a realm role (`auth.require_admin`),
  on purpose: it's the bootstrap authority that hands out every DB-held
  permission, so it can't itself live in the store it grants access to.
- **project owner** (DB row) — full control of that project's namespaces;
  also implicitly `maintainer` on every namespace of that project, *derived*
  on read rather than duplicated as grant rows (so ownership and per-namespace
  roles can never drift out of sync).
- **namespace grant** (DB row) — explicit `maintainer` or `viewer` on one
  specific namespace.

Out-of-scope resources return **404, not 403** (`authz.py`'s own docstring):
a 403 would confirm to an unauthorized caller that a given project ID exists.

Per-route, authorization is either a decorator-level role gate or a
body-level ownership/scope check — I walked every route in `main.py` and
every one has one of these:

| Mechanism | Used by |
|---|---|
| `Depends(require_admin)` | `DELETE /projects/{id}`, `POST`/`DELETE /users/{id}/project-manager`, the owners add/remove endpoints |
| `Depends(require_admin_or_project_manager)` | `POST /projects` (self-service project creation) |
| `Depends(require_operator)` | every `/internal/*` route — requires specifically teams-operator's identity (SVID `sub` or, in legacy mode, `azp`), not just any authenticated caller |
| `authz.require_project_owner(...)` (body) | namespaces add/remove, source-repos add/remove, GitHub connection endpoints, `/github/register-url`, `/github/install-url` |
| `authz.require_visible_project(...)` (body) | `GET /projects/{id}`, compliance, events, applications (per-project) |
| `authz.require_namespace_manager(...)` (body) | `POST`/`DELETE /access` (granting/revoking namespace access) |
| `authz.require_any_owner(...)` (body) | `GET /users`, `GET /access` — the user-management surface: admins and anyone who owns at least one project (non-owners have nobody to manage) |
| `authz.scoped_projects(...)` (body, implicit filter) | `GET /projects`, `GET /compliance`, `GET /namespace-status`, `GET /applications` — list endpoints narrowed to the caller's visible projects/namespaces |

The only routes with **no** authorization beyond "valid authenticated user"
are `/me`, `/kubeconfig`, and `/priority-classes` — each deliberately: the
first two are about the caller's own identity/access, and the third is an
explicitly non-project-scoped shared tier catalog (its own comment: "every
project shares the same tier catalog").

## Where things live

| Concern | File |
|---|---|
| Token/SVID validation, `PUBLIC_PATHS`, global dependency wiring | `platform-idp/teams-management/teams-api/auth.py` |
| Authorization resolution (ownership, grants, scoping) | `platform-idp/teams-management/teams-api/authz.py` |
| App-level `dependencies=` wiring, all route decorators | `platform-idp/teams-management/teams-api/main.py` |
| Browser token acquisition | `platform-idp/teams-management/teams-app/src/app/services/auth.service.ts`, `config/keycloak.config.ts` |
| Browser token attachment | `platform-idp/teams-management/teams-app/src/app/interceptors/auth.interceptor.ts` |
| CLI token acquisition | `platform-idp/teams-management/teams-cli/teams_cli.py` (`login`, loopback PKCE) |
| Operator SVID minting (sidecar config) | `platform-infra/apps/developer-control/teams-operator/manifests/openbao-agentconfig-templates/operator-spiffe-helper.conf` |
| `INTERNAL_AUTH_MODE`/`TEAMS_API_AUTH` live values | `platform-infra/apps/developer-control/{teams-api,teams-operator}/manifests/deployment.yaml` |
| SVID cutover history / retired Keycloak-operator path | `platform-infra/docs/keycloak-write-ownership-and-internal-auth.md` |
| Specific ownership-check call sites (GitHub flow, project creation) | `platform-infra/docs/self-service-boundaries.md` |
