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

## OpenBao — one-time init + auto-unseal keys

OpenBao uses a Shamir seal, so it comes up **sealed** (and, on fresh storage,
**uninitialized**). Initialize it once and create the Secret the auto-unseal
watcher reads. Both key artifacts are git-ignored — keys never enter the repo.

```sh
# Initialize (5 shares / threshold 3). Save the JSON somewhere safe — it also
# contains the root token, which is your only admin credential.
kubectl -n openbao exec openbao-0 -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 bao operator init -key-shares=5 -key-threshold=3 -format=json' \
  > bootstrap/init-keys.json   # already git-ignored (init-keys.json*)

# Unseal now, interactively (needs 3 of the 5 keys) — the watcher below only
# handles *future* seals, it doesn't do this first one for you.
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[0]' bootstrap/init-keys.json)"
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[1]' bootstrap/init-keys.json)"
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[2]' bootstrap/init-keys.json)"

# Create the unseal-keys Secret the watcher consumes (threshold = 3 keys).
kubectl -n openbao create secret generic openbao-unseal-keys \
  --from-literal=UNSEAL_KEY_1="$(jq -r '.unseal_keys_b64[0]' bootstrap/init-keys.json)" \
  --from-literal=UNSEAL_KEY_2="$(jq -r '.unseal_keys_b64[1]' bootstrap/init-keys.json)" \
  --from-literal=UNSEAL_KEY_3="$(jq -r '.unseal_keys_b64[2]' bootstrap/init-keys.json)"
```

From then on the `openbao-unseal` Deployment (GitOps-managed, in
`apps/security/openbao/`) unseals the server automatically on every pod
restart. If that pod was already up and stuck in `CreateContainerConfigError`
(secret didn't exist yet when it was scheduled), restart it once so it
picks up the Secret you just created — Deployments don't re-read `envFrom`
into already-running pods:

```sh
kubectl -n openbao delete pod -l app.kubernetes.io/name=openbao-unseal
```

A full **cluster/PVC recreate wipes OpenBao's storage** — re-run all the
commands above (init produces new keys) when that happens. Once you're done,
move `bootstrap/init-keys.json` (root token + all 5 raw keys) out of the repo
checkout and into a password manager or other secret store — it's git-ignored
so it won't get committed, but it's still sitting there in plaintext on disk.

**If storage is `Initialized: true` but `openbao-unseal-keys` is missing or
wrong** (e.g. the Secret was deleted, or the keys were lost before being
saved anywhere): those Shamir keys are gone for good — they only ever exist
at the moment `bao operator init` runs. There is no recovery short of
wiping storage and starting over:

```sh
kubectl -n openbao delete pod openbao-0
kubectl -n openbao delete pvc data-openbao-0
```

Wait for the StatefulSet to recreate `openbao-0` with a fresh PVC (`bao
status` should show `Initialized: false`), then redo the init + unseal +
Secret steps above.

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
