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

## OpenBao — enable KV + JWT auth for team-* secrets (SPIFFE trust)

One-time setup so `team-*` workloads can read/write secrets in OpenBao
using their SPIRE-issued identity — no static credential anywhere. See
`apps/security/tenant-guardrails/manifests/openbao-*.yaml` (the mutations
that give every tenant pod a JWT-SVID + an `openbao-agent` sidecar) and
`teams_operator.py`'s `ensure_openbao_access` (which creates the
per-namespace policy/role/agent-config as namespaces are provisioned). All
commands below run with the root token from `bootstrap/init-keys.json`
(`BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)`).

```sh
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)

# 1) KV-v2 mount for every team's secrets, isolated by path + policy (see
#    openbao-policy-templates/team.hcl) rather than one mount per team.
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao secrets enable -path=kv-teams kv-v2"

# 2) JWT auth method, trusting SPIRE's OIDC discovery provider as the JWKS
#    source. That provider serves its JWKS over HTTPS using its own SPIFFE
#    X.509-SVID as the TLS cert (not a public-CA cert) — so OpenBao needs
#    the SPIRE trust bundle's CA to validate that connection.
#
#    The `spire-bundle` ConfigMap holds a SPIFFE JWKS bundle (JSON), not a
#    ready PEM file — extract the x509-svid entries' certs into PEM first.
kubectl get cm spire-bundle -n spire-server -o jsonpath='{.data.bundle\.spiffe}' \
  > /tmp/bundle.spiffe.json
python3 - /tmp/bundle.spiffe.json > /tmp/spire-bundle.pem <<'PYEOF'
import json, sys, textwrap
with open(sys.argv[1]) as f:
    bundle = json.load(f)
for key in bundle.get("keys", []):
    if key.get("use") == "x509-svid":
        for der_b64 in key.get("x5c", []):
            print("-----BEGIN CERTIFICATE-----")
            print("\n".join(textwrap.wrap(der_b64, 64)))
            print("-----END CERTIFICATE-----")
PYEOF

kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao auth enable jwt"
kubectl -n openbao cp /tmp/spire-bundle.pem openbao-0:/tmp/spire-bundle.pem
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write auth/jwt/config \
     oidc_discovery_url=https://spire-spiffe-oidc-discovery-provider.spire-server.svc.cluster.local \
     oidc_discovery_ca_pem=@/tmp/spire-bundle.pem"
```

**This bundle is short-lived (SPIRE's default root rotates roughly daily in
this cluster — confirmed by inspecting the extracted certs' validity
window) — `oidc_discovery_ca_pem` above will go stale and JWT logins will
start failing with a TLS trust error.** Re-run the extraction + `bao write
auth/jwt/config` step whenever that happens (no watcher automates this
today — same class of manual-refresh caveat as `platform-tls` below).

```sh
# 3) Bootstrap the operator's own trust — chicken-and-egg: teams-operator
#    creates every project-<namespace> policy/role itself once it's running
#    (ensure_openbao_access), but it needs its *own* role to exist first.
#    bound_claims.sub matches this Deployment's own SPIFFE ID (see
#    apps/developer-control/teams-operator/manifests/deployment.yaml's
#    spiffe-helper sidecar — same trust chain as tenant workloads, just
#    scoped to a management policy instead of one namespace's KV path).
#    Paths are "project-*" (not "team-*") to match teams-api's
#    default_namespace()/ordered_namespace() output - if that prefix ever
#    changes again, this policy must change with it or every namespace's
#    OpenBao policy/role write starts 403ing (confirmed live: this exact
#    drift happened once already when the prefix moved team- -> project-).
kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao policy write teams-operator-admin-policy -" <<'EOF'
path "sys/policies/acl/project-*" {
  capabilities = ["create", "read", "update", "delete"]
}
path "auth/jwt/role/project-*" {
  capabilities = ["create", "read", "update", "delete"]
}
EOF

# `bound_claims` is a map field — the CLI's `key=value` shorthand doesn't
# parse a nested map correctly (fails with "expected type
# 'map[string]interface {}', got unconvertible type 'string'"), confirmed
# live rather than assumed. Use a JSON body over stdin instead, same as the
# policy write above.
kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write auth/jwt/role/teams-operator-admin -" <<'EOF'
{
  "role_type": "jwt",
  "bound_audiences": ["openbao"],
  "user_claim": "sub",
  "bound_claims_type": "glob",
  "bound_claims": {
    "sub": "spiffe://platform.local/ns/engineering-platform/sa/teams-operator"
  },
  "token_policies": ["teams-operator-admin-policy"],
  "token_ttl": "15m",
  "token_max_ttl": "1h"
}
EOF
```

From then on `teams-operator` creates every `project-<namespace>` policy/role
as namespaces are provisioned — no further manual OpenBao steps for new
teams. A full cluster/PVC recreate wipes this configuration along with
everything else in OpenBao's storage (same as the KV init above) — redo
steps 1–3 after that.

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

## OpenBao — enable OIDC login via Keycloak

`bootstrap/enable-oidc-sso.sh openbao` runs everything below (and is
re-runnable — it checks before enabling the auth method, and `bao write` is
otherwise a natural overwrite). The commands are kept here too for anyone
who wants to run them by hand or see exactly what the script does.

One-time setup so a human can log into the OpenBao UI/CLI with their
Keycloak identity instead of a static token, using OpenBao's native `oidc`
auth method against the "openbao" client in `apps/security/keycloak`'s
realm import. Commands run with the root token from
`bootstrap/init-keys.json` (`BAO_TOKEN=$(jq -r '.root_token'
bootstrap/init-keys.json)`), same as the JWT/SPIRE setup above — this is a
separate auth method (`oidc`, mounted alongside the existing `jwt` mount
used for workload identity, not a replacement for it).

```sh
BAO_TOKEN=$(jq -r '.root_token' bootstrap/init-keys.json)

# 1) Enable the oidc auth method.
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao auth enable oidc"

# 2) Point it at Keycloak's "teams" realm. oidc_discovery_ca_pem is needed
#    because Keycloak's issuer is only reachable over the self-signed
#    platform-tls cert (see the section above) — same platform-tls Secret
#    already present in the openbao namespace for its own ingress.
kubectl get secret platform-tls -n openbao -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/platform-tls.crt
kubectl -n openbao cp /tmp/platform-tls.crt openbao-0:/tmp/platform-tls.crt
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write auth/oidc/config \
     oidc_discovery_url=https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams \
     oidc_client_id=openbao \
     oidc_client_secret=dev-openbao-oidc-secret-change-me \
     default_role=default \
     oidc_discovery_ca_pem=@/tmp/platform-tls.crt"
rm /tmp/platform-tls.crt

# 3) A role covering both the UI and `bao login -method=oidc` CLI flows -
#    redirect URIs must exactly match the "openbao" Keycloak client's
#    redirectUris. `policies=default` is the modest baseline every OIDC
#    login gets (Vault/OpenBao's built-in read-your-own-token policy);
#    step 4 below layers admin access on top for a specific group, via
#    identity groups rather than editing this role's policies (which would
#    hand that access to *everyone* who logs in via oidc, not just admins).
kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write auth/oidc/role/default -" <<'EOF'
{
  "role_type": "oidc",
  "bound_audiences": ["openbao"],
  "allowed_redirect_uris": [
    "https://openbao.127.0.0.1.sslip.io:8443/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback"
  ],
  "user_claim": "preferred_username",
  "groups_claim": "groups",
  "policies": ["default"],
  "ttl": "1h"
}
EOF

# 4) Give the "argocd-admins" Keycloak group (Argo CD and Harbor already
#    treat this as "the platform admins") root-equivalent access on login -
#    OpenBao/Vault will never mint a token carrying the literal built-in
#    "root" policy through any auth method (only `bao operator init` /
#    `generate-root` can produce a real root token; this is a hard security
#    restriction, not a config gap), so `path "*"` + sudo is the standard
#    stand-in. Bound via an *external identity group* rather than adding to
#    the role's `policies` above, since a role's policies apply to every
#    login through it regardless of the user's actual groups - this is what
#    makes it apply only to argocd-admins members.
kubectl -n openbao exec -i openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao policy write openbao-admin-policy -" <<'EOF'
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write identity/group/name/openbao-admins type=external policies=openbao-admin-policy"

# Group-alias creation 400s if one's already bound to this mount+name, so
# this is the one step that isn't a plain overwrite - check first.
GROUP_ID=$(kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao read -format=json identity/group/name/openbao-admins" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"]["id"])')
OIDC_ACCESSOR=$(kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao auth list -format=json" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["oidc/"]["accessor"])')
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 BAO_TOKEN=$BAO_TOKEN bao write identity/group-alias name=argocd-admins mount_accessor=$OIDC_ACCESSOR canonical_id=$GROUP_ID"
```

Log in via the UI's "OIDC" button at `https://openbao.127.0.0.1.sslip.io:8443/ui/`,
or from the CLI with `bao login -method=oidc` (opens a browser; needs
`http://localhost:8250/oidc/callback` reachable, which is why that URI is
in the role above alongside the UI one). Anyone in Keycloak's
`argocd-admins` group (just `admin` today) gets `openbao-admin-policy`
merged in automatically via the identity group, on top of the `default`
baseline everyone else gets. A full cluster/PVC recreate wipes all of this
along with everything else in OpenBao's storage — redo steps 1–4 after
that (or just re-run `bootstrap/enable-oidc-sso.sh openbao`).

## Harbor — enable OIDC login via Keycloak

`bootstrap/enable-oidc-sso.sh harbor` runs everything below (and is
re-runnable — it skips creating `harbor-ca-bundle` if it already exists,
waits for the rollout Argo CD already triggered before calling the API, and
the Configurations PUT is a natural overwrite either way).

One-time setup so a human can log into Harbor with their Keycloak identity
instead of a local Harbor account, using Harbor's built-in OIDC auth mode
against the "harbor" client in `apps/security/keycloak`'s realm import.
Requires `platform-tls` to already exist in the `harbor` namespace (see
above) and the `caBundleSecretName` wired into
`apps/integration-delivery/harbor/application.yaml` to have synced (Harbor
core needs to trust that same self-signed cert to reach Keycloak's OIDC
discovery endpoint).

```sh
# 1) Harbor's chart wants the CA under key `ca.crt`, not `tls.crt` — derive
#    it from the same platform-tls cert rather than generating a second one.
kubectl get secret platform-tls -n harbor -o jsonpath='{.data.tls\.crt}' \
  | base64 -d > /tmp/platform-tls.crt
kubectl -n harbor create secret generic harbor-ca-bundle \
  --from-file=ca.crt=/tmp/platform-tls.crt
rm /tmp/platform-tls.crt
# Wait for Argo CD to sync the caBundleSecretName change and restart core/
# jobservice/registry/trivy before step 2, or the OIDC discovery call below
# still hits the untrusted-CA error.

# 2) Configure OIDC auth mode via Harbor's own API (no UI equivalent that's
#    scriptable) — admin/Harbor12345 is the same DEMO credential used
#    elsewhere in this file. oidc_admin_group grants Harbor's system-admin
#    role to anyone in Keycloak's "argocd-admins" group (reusing that group
#    rather than inventing a Harbor-specific one — same demo user, "admin",
#    is already a member). Once auth_mode is oidc_auth, only the built-in
#    local "admin" account can still fall back to its Harbor password —
#    every other account must use "LOGIN VIA OIDC PROVIDER".
curl -sk -u admin:Harbor12345 -X PUT \
  https://harbor.127.0.0.1.sslip.io:8443/api/v2.0/configurations \
  -H "Content-Type: application/json" \
  -d '{
        "auth_mode": "oidc_auth",
        "oidc_name": "Keycloak",
        "oidc_endpoint": "https://platform-auth.127.0.0.1.sslip.io:8443/auth/realms/teams",
        "oidc_client_id": "harbor",
        "oidc_client_secret": "dev-harbor-oidc-secret-change-me",
        "oidc_scope": "openid,profile,email",
        "oidc_verify_cert": true,
        "oidc_auto_onboard": true,
        "oidc_user_claim": "preferred_username",
        "oidc_admin_group": "argocd-admins",
        "oidc_groups_claim": "groups"
      }'
```

Log in via the "LOGIN VIA OIDC PROVIDER" button on Harbor's login page. A
full cluster/PVC recreate wipes both the `harbor-ca-bundle` Secret and
Harbor's own database (where this auth config lives) — redo both steps
after that.

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
