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

## `platform-tls` — the wildcard cert for `*.127.0.0.1.sslip.io`

Every app exposed over HTTPS (OpenBao, Keycloak, Harbor, teams-api, teams-app)
references a Secret named `platform-tls` for its Ingress TLS. It's a
self-signed cert, **created manually per namespace and NOT auto-replicated**
— each Ingress's `secretName: platform-tls` must exist in *that* Ingress's
own namespace, or nginx falls back to its default fake cert (`CN=ingress.local`)
for that host and every client — browser, curl, containerd — fails TLS
verification. Nothing generates this automatically (cert-manager here is only
wired to a Let's Encrypt ACME issuer, which cannot work for a local
`sslip.io` cluster — see `apps/security/cert-manager/manifests/`).

Generate it once and copy it into every namespace that needs it:

```sh
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
  -keyout /tmp/platform-tls.key -out /tmp/platform-tls.crt \
  -subj "/CN=*.127.0.0.1.sslip.io" \
  -addext "subjectAltName=DNS:*.127.0.0.1.sslip.io,DNS:127.0.0.1.sslip.io"

for ns in openbao harbor keycloak engineering-platform; do
  kubectl -n "$ns" create secret tls platform-tls \
    --cert=/tmp/platform-tls.crt --key=/tmp/platform-tls.key
done
rm /tmp/platform-tls.key /tmp/platform-tls.crt
```

A full cluster rebuild wipes all of these (Secrets aren't in git) — re-run
the above. You can reuse the same cert/key across rebuilds if you saved a
copy outside the repo; regenerating is equally fine since it's self-signed.

## Pulling images from Harbor on the kind nodes

Deployments like `teams-api`/`teams-app`/`teams-operator` reference images at
`harbor.127.0.0.1.sslip.io/platform/...`. That hostname is public DNS
(sslip.io embeds the IP in the name), so it always resolves to `127.0.0.1` —
fine for your browser or `docker login` on the host machine (kind maps host
port 8443 → the ingress), **broken for the kind nodes' own containerd**,
which resolves DNS independently and has nothing listening on its own
`127.0.0.1:443`. `apps/security/ratify/manifests/harbor-trust.yaml` fixes the
equivalent problem for Ratify (a Pod, resolves via CoreDNS) with a DNS
rewrite; that doesn't help containerd's node-level pull path, which never
consults CoreDNS. This needs three separate fixes, all at the Docker/node
level (outside Kubernetes' reach, so **not** GitOps-managed — redo after a
node or cluster rebuild):

```sh
# 1) Route the hostname to the in-cluster ingress from each node's own
#    network namespace (kube-proxy's rules make the ClusterIP reachable
#    there, same trick the CoreDNS rewrite relies on for Pods).
INGRESS_IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.clusterIP}')
for node in platform-base-control-plane platform-base-worker; do
  docker exec "$node" sh -c "grep -q harbor.127.0.0.1.sslip.io /etc/hosts || echo '$INGRESS_IP harbor.127.0.0.1.sslip.io' >> /etc/hosts"
done

# 2) Make containerd trust the self-signed platform-tls cert (otherwise:
#    "x509: certificate signed by unknown authority"). Needs the same
#    platform-tls.crt from the section above.
for node in platform-base-control-plane platform-base-worker; do
  docker cp /tmp/platform-tls.crt "$node:/usr/local/share/ca-certificates/platform-tls.crt"
  docker exec "$node" update-ca-certificates
  docker exec "$node" systemctl restart containerd
done

# 3) Harbor's `platform` project is private, so pulls need credentials too
#    ("no basic auth credentials" / "pull access denied"). A pull-only robot
#    account + imagePullSecret (the Deployments already reference
#    `harbor-pull` — see apps/developer-control/*/manifests/deployment.yaml):
ROBOT=$(curl -sk -u admin:Harbor12345 -X POST \
  "https://harbor.127.0.0.1.sslip.io:8443/api/v2.0/robots" \
  -H "Content-Type: application/json" \
  -d '{"name":"pull","duration":-1,"level":"project","permissions":[
        {"kind":"project","namespace":"platform",
         "access":[{"resource":"repository","action":"pull"}]}]}')
kubectl -n engineering-platform create secret docker-registry harbor-pull \
  --docker-server=harbor.127.0.0.1.sslip.io \
  --docker-username="$(echo "$ROBOT" | jq -r .name)" \
  --docker-password="$(echo "$ROBOT" | jq -r .secret)"
```

Why this is a *Docker exec* fix and not a Kubernetes manifest: steps 1-2
mutate the node containers' own `/etc/hosts` and CA trust store, which live
outside every Pod's network/mount namespace — no Job or DaemonSet running
*inside* the cluster can reach them without `privileged: true` + host
mounts + `nsenter`, which is a meaningfully bigger, standing security
tradeoff (this cluster runs Gatekeeper + Falco) than a one-time manual step
re-run after a rebuild.

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
