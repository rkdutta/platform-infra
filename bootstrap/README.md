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

## kubectl access via Keycloak (OIDC) + teams-api-synced RBAC

Team permissions (ownership, per-namespace viewer/maintainer grants) now have
real effect in the cluster: `teams-operator` mirrors them onto RoleBindings
per namespace (`view`/`edit` built-in ClusterRoles) plus one ClusterRoleBinding
(`teams-admins` → `cluster-admin`, one entry per Keycloak `admin`-role user).
None of that means anything, though, until the API server can authenticate a
human via their Keycloak token — by default it can't; only ServiceAccounts
exist as cluster identities. Two one-time, node-level steps make this real:

**1. Cluster connection info for `GET /kubeconfig`** — `teams-api` serves a
ready-to-use kubeconfig (downloadable from the Teams page, or via
`teams-cli kubeconfig`) built from a ConfigMap, not committed to git (the
API server's host port is assigned dynamically by Docker and can change
across a cluster recreate):

```sh
kubectl -n engineering-platform create configmap teams-api-k8s-access \
  --from-literal=server="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')" \
  --from-file=ca.crt=<(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d)
```

**2. OIDC on the API server** — `kube-apiserver` runs as a static pod on the
control-plane node, so this is a `docker exec` edit, not a cluster recreate:

```sh
# a) Trust the platform-tls CA for the OIDC issuer's TLS (reuses the cert
#    from the platform-tls section above).
docker cp /tmp/platform-tls.crt platform-base-control-plane:/etc/kubernetes/pki/oidc-ca.crt

# b) The issuer URL includes port 8443, which — unlike Harbor's 443 — only
#    exists as a *host*-level Docker port mapping, not reachable via the
#    ClusterIP trick. Docker Desktop's host.docker.internal reaches it anyway:
IP=$(docker exec platform-base-control-plane getent hosts host.docker.internal | awk '{print $1}')
docker exec platform-base-control-plane sh -c \
  "grep -q platform-auth.127.0.0.1.sslip.io /etc/hosts || echo '$IP platform-auth.127.0.0.1.sslip.io' >> /etc/hosts"

# c) Add the OIDC flags to the static pod manifest. IMPORTANT: don't leave a
#    backup copy (even named .yaml.bak) inside /etc/kubernetes/manifests/ —
#    kubelet's static-pod file source doesn't filter by extension, so a second
#    file defining a pod named "kube-apiserver" causes it to inconsistently
#    recreate from whichever one it picks (this bit us once already: a
#    stray backup sat in the directory during the edit, and kubelet kept
#    recreating the apiserver from the *stale* pre-edit copy for several
#    minutes with no error, no crash — just silently the wrong config, until
#    the extra file was moved out and the pod recreated cleanly). Edit the
#    manifest via a temp path elsewhere, or edit in place with a tool that
#    doesn't leave a same-directory backup:
docker exec platform-base-control-plane sh -c '
  sed "/--client-ca-file=/a\\
    - --oidc-issuer-url=https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams\\
    - --oidc-client-id=teams-cli\\
    - --oidc-username-claim=preferred_username\\
    - --oidc-username-prefix=-\\
    - --oidc-ca-file=/etc/kubernetes/pki/oidc-ca.crt\\
    - --oidc-groups-claim=groups" \
    /etc/kubernetes/manifests/kube-apiserver.yaml > /tmp/kube-apiserver.yaml.new
  mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/kube-apiserver.yaml.old
  mv /tmp/kube-apiserver.yaml.new /etc/kubernetes/manifests/kube-apiserver.yaml
'
```

Wait ~20s for kubelet to recreate the pod, then verify: `kubectl get nodes`
should still work (unrelated to OIDC — proves the API server came back at
all), and `--oidc-client-id=teams-cli` means only tokens issued *to* the
`teams-cli` client authenticate this way (`teams-ui` browser-login tokens
have a different `aud` and are correctly rejected here — that's expected,
not a bug, `teams-cli login` is what feeds `kubectl`).

Why `--oidc-username-prefix=-`: without it, k8s prefixes every OIDC username
with `<issuer>#`, which wouldn't match the plain usernames RBAC checks
expect. Why the issuer must be the exact
`https://platform-auth.127.0.0.1.sslip.io:8443/...` browser-facing URL and
can't be swapped for something more reachable: it has to match the `iss`
claim already baked into Keycloak's tokens byte-for-byte — there's no
aliasing mechanism in kube-apiserver's OIDC authenticator.

`--oidc-groups-claim=groups`: empirically verified there's **no** default
prefix for groups the way usernames get one — a token's raw `groups: [X]`
resolves to exactly `X` in a `SelfSubjectReview`, no `--oidc-groups-prefix`
needed. This is what lets teams-operator's static, Group-subject
RoleBindings (`{namespace}-viewer` / `{namespace}-maintainer` — see
teams-api's `_k8s_group_name`) match on the plain namespace-derived name.

A full cluster recreate wipes all of this (new API server port, fresh static
pod manifest, `teams-api-k8s-access` ConfigMap gone) — redo both steps.

**Developer setup, once the above is in place:** install the
[kubelogin](https://github.com/int128/kubelogin) plugin
(`brew install int128/kubelogin/kubelogin`), then download a kubeconfig from
the Teams page ("Download kubeconfig") or `GET /kubeconfig` directly — its
`exec:` stanza runs `kubectl oidc-login get-token` itself, doing its own PKCE
login against Keycloak's `teams-cli` client at `kubectl` invocation time; no
separate CLI login step needed first.

**How access actually propagates now**: teams-api mirrors grants/revokes/
ownership changes directly into Keycloak group membership at the moment
they happen (see `main.py`'s `_sync_group_membership` and its call sites),
with a periodic in-process reconciliation pass (`GROUP_RECONCILE_INTERVAL`,
default 60s) as a self-healing backstop against a missed sync. The
RoleBindings themselves (teams-operator's job) are static — created once per
namespace and never touched again. So a grant/revoke takes effect on the
affected user's *next token refresh* (Keycloak's normal token lifetime —
minutes), not their very next `kubectl` command — a deliberate tradeoff for
not having to patch a Kubernetes object on every access change (see
`platform-idp`'s teams-api commit history for the full "why").

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
