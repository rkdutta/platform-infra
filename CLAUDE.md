# platform-infra — GitOps source of truth

Argo CD `Application` manifests for everything that runs in the cluster,
organized by **plane** (`apps/<plane>/<app>/` — `resource`, `security`,
`monitoring`, `integration-delivery`, `developer-control`, plus the
`tenant-workloads` landing zone) and ordered by **sync-wave** (0–5, see
`bootstrap/README.md`'s "Rollout order" table). App-of-apps bootstrap lives
in `bootstrap/`. Own git remote (`rkdutta/platform-infra`) — a feature that
changes app behavior needs a commit here (the `image:` tag bump in the
relevant `manifests/deployment.yaml`) alongside the code commit in
`platform-idp`. See `../CLAUDE.md` for the platform-wide picture.

## Features this repo delivers

### Bootstrap automation (`bootstrap/`)
`Makefile` orchestrates the full post-`terraform apply` bootstrap
(`make bootstrap`): out-of-band secrets → AppProjects → root app → OpenBao
init/unseal → Harbor + Ratify pull robots → Harbor OIDC SSO → OpenBao
runtime access (kv mount / human SSO / workload jwt) → the
`teams-api-k8s-access` ConfigMap. See `bootstrap/README.md` for the full
manual-equivalent runbook, and `create-secrets.sh` / `openbao.sh` /
`enable-openbao-{kv,jwt}.sh` / `enable-oidc-sso.sh` / `teams-api-access.sh`
for what each step actually does — all idempotent, safe to re-run
individually or as the full `make bootstrap` chain after a cluster rebuild.

### Self-service Project reconciliation targets
`teams-operator` (code lives in `platform-idp`) reconciles every namespace's
cluster-side state from `teams-api`; the **targets** it reconciles into live
here:
- **k8s RBAC** — static RoleBindings per namespace bound to Keycloak groups
  `{namespace}-viewer` / `{namespace}-maintainer`.
- **Argo CD RBAC** — a per-project Casbin policy block appended to
  `argocd-rbac-cm`, reusing the *same* Keycloak groups via `g,` lines (no
  separate Argo-CD-specific group — deliberate, to avoid group sprawl).
- **OpenBao secrets** (`apps/security/openbao/`,
  `apps/security/tenant-guardrails/`) — one KV-v2 mount (`kv/`),
  path-isolated per project rather than one mount per project, reached two
  ways: *workload* access via SPIFFE/SPIRE JWT-SVID → OpenBao `jwt` auth
  (full mechanism in `docs/openbao-spiffe-access.md`), and *human* access
  via OIDC SSO login mapped through OpenBao identity-group aliases to the
  same viewer/maintainer policy pair. Both the access wiring and the actual
  secret data get torn down when a project is deleted.
- **Quotas/limits/network policy** — static per-tier templates applied per
  namespace.
- **Harbor image pull secret** — created per namespace.

### Identity (Keycloak, `apps/security/keycloak/`)
Keycloak's `teams` realm is the one IdP for the whole platform — the
platform UI/CLI (human OIDC), Argo CD (native OIDC), OpenBao (OIDC for
humans + a separate `jwt` method for SPIFFE workloads), Harbor (OIDC), and
the apiserver (OIDC, via `platform-base`'s `apiserver-oidc.tf`). **The
inline realm-import JSON in `application.yaml` and the standalone
`teams-realm.json` reference file are two separate copies kept in sync by
hand** — no mechanism enforces it; check both when touching clients, roles,
or groups.

### SPIFFE/SPIRE workload identity (`apps/security/spire/`)
SPIRE issues X.509-SVIDs and JWT-SVIDs to every workload; its OIDC discovery
provider is what OpenBao's `jwt` auth method trusts for workload logins. The
discovery provider's HTTPS serving cert is issued by cert-manager from the
stable `platform-tls` CA (the Helm values' `tls.certManager`, plus an
explicit `dnsNameTemplates` entry so the cert covers the full
`...svc.cluster.local` FQDN the discovery doc's `issuer` claim uses) —
deliberately not a SPIRE-native X.509-SVID, because SPIRE's own root used to
rotate roughly daily and repeatedly broke OpenBao's cached CA pin with a
TLS trust error.

### Supply chain: Harbor + Ratify + Gatekeeper
(`apps/integration-delivery/harbor/`, `apps/security/ratify/`,
`apps/security/gatekeeper/`)
- Harbor is the platform's private registry (project `platform`), OIDC-login
  capable, GHCR-replication-fed.
- Node-level image pulls need three fixes; two are now automated by
  `platform-base` (`/etc/hosts` routing, containerd CA trust). **The
  still-manual piece is the Harbor pull robot** — scripted as
  `make harbor-pull` (the platform's own images) and `make
  ratify-harbor-pull` (Ratify's own outbound pulls; a separate robot for a
  narrower blast radius) — both need Harbor's live API so can't be
  Terraform'd, run once Harbor is Synced & Healthy.
- Ratify verifies keyless cosign signatures (Sigstore/Fulcio/Rekor) at
  admission via Gatekeeper's external-data API, trusting the GitHub Actions
  OIDC identity of each demo repo's `release.yml` workflow
  (`apps/security/ratify/application.yaml`'s `cosign.keyless` config) — see
  `docs/keyless-signing-trust-chain.md`.

### Self-service cloud resource provisioning (in progress)
Design locked in `docs/multicloud-resource-access.md`: **Crossplane** (core
`2.3.4` installed, `apps/resource/crossplane`) with a curated Compositions
catalog; the self-service unit is a `ResourceAccess` (a resource + a bound
workload identity), not a bare resource. SPIRE-rooted, no-static-key trust:
AWS via IAM Roles Anywhere (X.509-SVID, ACM Private CA as both the SPIRE
upstream CA and the trust anchor), Azure via Entra Workload Identity
Federation (JWT-SVID, needs SPIRE's OIDC discovery publicly reachable),
databases via OpenBao dynamic secrets. Azure SQL provider scaffolded
(`apps/resource/crossplane-providers`), not yet wired with
credentials/Compositions. Crossplane owns the cloud objects here;
`teams-operator` (in `platform-idp`) owns the OpenBao/SPIFFE access wiring
and teardown — see `platform-idp/CLAUDE.md`'s pending section for that half.

## Known gotchas specific to this repo

- **Image deploy workflow**: build with the real Dockerfile, tag
  `harbor.127.0.0.1.sslip.io/platform/<app>:<next-version>` (pushing from
  the host needs the `:8443` port — the bare hostname resolves to 443,
  which nothing listens on host-side), and always also `kind load
  docker-image ... --name platform-base` as a fallback, since
  `imagePullPolicy: IfNotPresent` skips a flaky Harbor push entirely. Then
  bump the tag in the app's `manifests/deployment.yaml` here. Argo CD's own
  polling lags — `kubectl patch application root -n argocd --type merge -p
  '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'`
  forces it, but **child** Applications (e.g. `teams-app`) can need their
  own separate hard-refresh even after `root` has synced.
- **Never run `bao token revoke -self` with the root token set as
  `BAO_TOKEN`** — it revokes the root token itself. Recovery needs `bao
  operator generate-root` with 3-of-5 unseal shares from
  `bootstrap/init-keys.json`, which needs the legacy unauthenticated
  `/sys/generate-root` endpoints temporarily re-enabled
  (`disable_unauthed_generate_root_endpoints = false` in the
  `openbao-config` ConfigMap's listener block) — and Argo CD's self-heal
  reverts that edit near-instantly unless `argocd-application-controller`
  is scaled to 0 first, then back to 1 once done. Editing OpenBao's server
  config like this is a security-sensitive action the auto-mode permission
  classifier blocks by default, regardless of which tool performs it — get
  explicit sign-off on the specific step rather than routing around it.
- **zsh doesn't word-split unquoted `$var` in `for x in $VAR`** the way bash
  does — use arrays (`arr=(a b c); for x in "${arr[@]}"`) for any
  multi-item loop over OpenBao objects etc. in these bootstrap scripts.
- **`kubectl exec` needs `-i`** to actually forward heredoc/piped stdin —
  without it, a `python3 -`/`bao ... -` script silently runs against empty
  input and exits 0 with no output, which reads exactly like a hang.
