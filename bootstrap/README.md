# Bootstrap — platform-infra GitOps

The platform is organised as a **plane-based reference architecture** and bootstrapped
as a single, health-gated **app-of-apps**. See `docs/platform-reference-architecture.pdf`
for the full design.

## Two axes, kept separate

| Axis | Question it answers | Where it lives |
|------|--------------------|----------------|
| **Plane** (grouping) | Who owns this? | `apps/<plane>/<app>/` · `plane:` label · `project:` → `projects/<plane>.yaml` |
| **Wave** (ordering) | When does it install? | `argocd.argoproj.io/sync-wave: "0..5"` on each leaf app |

Planes: `resource`, `security`, `monitoring`, `integration-delivery`,
`developer-control`, plus the `tenant-workloads` landing zone.

## Bootstrap order

Argo CD itself is installed by `platform-base` (Terraform). Then, once:

```sh
export KUBECONFIG=$PWD/kubeconfig

# 1. Private-repo credentials (this repo is private). NOT committed — token lives
#    only in your working copy; the file is git-ignored.
kubectl apply -f bootstrap/repo-credentials.yaml

# 2. The 6 plane AppProjects (leaf apps reference these; must exist first).
kubectl apply -f projects/

# 3. The app-of-apps root. This is the only manual apply of an app manifest;
#    everything else flows through GitOps from here.
kubectl apply -f bootstrap/root-app.yaml
```

Watch it fan out in wave order:

```sh
kubectl get applications -n argocd -w
# or the UI: http://argocd.127.0.0.1.sslip.io:8080
```

## Rollout order (health-gated)

Each wave must be **Synced and Healthy** before the next begins:

| Wave | Contents |
|------|----------|
| 0 | ingress-nginx, cloudnative-pg, cert-manager, spire-crds, gatekeeper, metrics-server |
| 1 | issuers, spire, openbao, keycloak-db, trivy-operator, falco, monitoring-stack |
| 2 | keycloak, ratify (+config), trivy-gatekeeper, harbor |
| 3 | teams-operator, teams-api |
| 4 | teams-app |
| 5 | demo-api, demo-api-py, demo-web, demo-web-py, demo-teams |

## After bootstrap

Never `kubectl apply` an app manifest again — edit `apps/<plane>/<app>/…`, push to
`main`, and Argo CD reconciles. Argo CD self-heal will revert manual `kubectl` edits.
