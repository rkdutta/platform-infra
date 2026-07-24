# SPIFFE-Authenticated OpenBao Access for Team Namespaces

Any pod in a `team-*` namespace can read/write secrets scoped to its own
namespace in OpenBao, with **no static credential anywhere** — no Kubernetes
Secret holding an OpenBao token, no API key baked into an image, nothing a
human provisions per app. Instead, a pod's own cryptographic identity (its
**SVID**, issued by SPIRE) is what OpenBao trusts. This doc explains the
mechanism end to end: what SPIFFE/SPIRE actually give you, how that identity
gets turned into OpenBao access, and the exact sequence of events from "a pod
starts" to "an app calls a local URL and gets its secret back."

This is **opt-in per workload**, not automatic for every tenant pod: add the
label `platform.example.com/openbao-access: "true"` to a Deployment's or
Rollout's own `metadata.labels` (not the pod template's) to get it. Without
the label, a workload gets none of the extra containers/volumes described
below — see [Why a label, not an annotation](#why-a-label-not-an-annotation)
for why opt-in works this way.

If you just want the file map, jump to [Where things live](#where-things-live).
If you want the "why did we choose this" design rationale, see the PR/commit
history for `apps/security/tenant-guardrails`'s `openbao-*.yaml` and
`apps/developer-control/teams-operator`'s `openbao-*-templates/` — this doc
is about *how it works*, not why it was designed this way.

## Core concepts, briefly

**SPIFFE** (Secure Production Identity Framework For Everyone) is a
standard for giving workloads a verifiable identity, independent of network
location. **SPIRE** is the implementation running in this cluster
(`apps/security/spire/`).

- **Trust domain**: the root of trust everything else hangs off. This
  cluster's trust domain is `platform.local` (set once in
  `apps/security/spire/application.yaml`'s Helm values — changing it later
  re-bootstraps the entire trust root, so it's treated as fixed).
- **SPIFFE ID**: a URI identifying a workload, of the form
  `spiffe://<trust domain>/<path>`. In this cluster, every pod's SPIFFE ID is
  templated from its namespace + ServiceAccount:
  `spiffe://platform.local/ns/<namespace>/sa/<serviceaccount>`. This
  templating is defined by a `ClusterSPIFFEID` resource
  (`spire-server-spire-default`, a fallback rule matching every namespace
  except `spire-system`/`spire-server`) — it's cluster config, not something
  each app opts into.
- **SVID** (SPIFFE Verifiable Identity Document): the actual credential
  proving a workload holds a given SPIFFE ID. Comes in two flavors:
  - **X.509-SVID**: a short-lived certificate. Good for mTLS.
  - **JWT-SVID**: a short-lived signed JWT. Good for authenticating to an
    HTTP API that expects a bearer token — which is what OpenBao's `jwt`
    auth method wants. **This is the flavor used here.**
- **Workload API**: a local gRPC API (a Unix socket) that SPIRE's agent
  exposes on every node. A workload asks it "who am I, and prove it" and
  gets back a freshly-issued SVID. Crucially, SPIRE decides *what* SPIFFE ID
  to hand back based on facts about the calling process (which pod, which
  namespace, which ServiceAccount) — a workload can't just ask to be anyone.
  Pods reach this socket via the `csi.spiffe.io` CSI driver, mounted as an
  ephemeral volume.
- **OIDC Discovery Provider**: a small service
  (`spire-spiffe-oidc-discovery-provider`, in the `spire-server` namespace)
  that exposes SPIRE's JWT-SVID signing keys as a standard JWKS document —
  the same shape any OIDC-compliant relying party (like OpenBao) knows how
  to consume. This is what lets OpenBao verify a JWT-SVID's signature
  *without* SPIRE and OpenBao needing any direct, bespoke integration.

**None of the above was built for this feature** — SPIRE, the trust domain,
the fallback `ClusterSPIFFEID`, and the OIDC discovery provider were already
running in this cluster and already issuing every pod an identity. The work
described below is entirely about *consuming* that pre-existing identity:
getting it into a pod, and getting OpenBao to trust it.

## The trust chain, end to end

```
 ┌──────────────────────────────┐
 │  SPIRE (already running)     │
 │  trust domain: platform.local│
 │                              │
 │  issues every pod an SVID:   │
 │  spiffe://platform.local/    │
 │    ns/<namespace>/sa/<sa>    │
 └──────────────┬───────────────┘
                │ JWT-SVID (audience "openbao")
                ▼
 ┌──────────────────────────────────────────────┐
 │  tenant pod (e.g. demo-api-go)               │
 │                                              │
 │  ┌──────────────┐   JWT file   ┌──────────┐  │
 │  │ spiffe-helper│ ───────────► │  openbao │  │
 │  │  (sidecar)   │              │  -agent  │  │
 │  └──────────────┘              │ (sidecar)│  │
 │                                └──────┬───┘  │
 │  ┌───────────────┐   localhost:8207    │     │
 │  │  app container│◄───────────────────┘      │
 │  │  (unmodified) │  KV read/write, no token  │
 │  └───────────────┘                           │
 └──────────────────────────────────────────────┘
                │ bao write/read via
                │ auth/jwt/login -> kv-teams/data/<namespace>/*
                ▼
 ┌─────────────────────────────────────────────┐
 │  OpenBao                                    │
 │  - jwt auth method, trusts SPIRE's OIDC     │
 │    discovery provider's JWKS                │
 │  - per-namespace role: bound_claims.sub     │
 │    matches spiffe://platform.local/ns/<ns>/*│
 │  - per-namespace policy: scoped to          │
 │    kv-teams/data/<namespace>/*              │
 └─────────────────────────────────────────────┘
```

Two things make this work that are easy to gloss over:

1. **OpenBao never talks to SPIRE directly for each login.** It fetches
   SPIRE's public signing keys (JWKS) from the OIDC discovery provider once
   (and periodically refreshes), then verifies JWT-SVID signatures locally,
   the same way any OIDC relying party validates a JWT without a round trip
   per request.
2. **The JWT-SVID's own claims are the identity.** OpenBao doesn't ask "is
   this pod who it says it is" — it asks "is this JWT validly signed by a
   key I trust, and does its `sub` claim match a role's `bound_claims`."
   The `sub` claim (`spiffe://platform.local/ns/team-jack-dev/sa/default`)
   is what SPIRE put there when it issued the SVID, based on the pod's real
   namespace/ServiceAccount — that's the actual security boundary.

## Step by step: what happens when a tenant pod starts

This is the part that's easy to lose track of, because five different
components each do one small thing. Concretely, for a pod in `team-jack-dev`
whose Deployment/Rollout carries `platform.example.com/openbao-access: "true"`
(without the label, none of steps 1-2 fire — the pod is admitted unchanged):

1. **Admission time.** The pod's Deployment/Rollout is submitted to the API
   server. Two Gatekeeper `Assign` mutations
   (`apps/security/tenant-guardrails/manifests/openbao-spiffe-volume-*.yaml`)
   fire first, adding to the pod spec (only if not already present):
   - a `csi.spiffe.io` ephemeral volume (`spiffe-workload-api`) — the path
     to the Workload API socket.
   - an `emptyDir` (`openbao-agent-shared`) — scratch space the two
     sidecars use to hand data to each other.
   - a `configMap` volume (`openbao-agent-config`) — referencing a
     ConfigMap that must already exist *in that namespace* (see step 0
     below; this is namespace-scoped, unlike the cluster-wide mutations).
2. **Still admission time.** Two more `Assign` mutations
   (`openbao-sidecar-*.yaml`) inject two containers into the same pod spec:
   `spiffe-helper` and `openbao-agent`. Neither existed in the app's own
   manifest — the app repo (e.g. `demo-api-go`) has no idea any of this is
   happening.
3. **Validation, after mutation.** Only now do Gatekeeper's *validating*
   constraints run against the now-mutated spec — including
   `tenant-images-from-harbor`, which is why the sidecar images have to be
   Harbor-hosted mirrors rather than `ghcr.io`/`quay.io` directly (see
   [Gotcha 1](#gotcha-1-mutation-then-validation-order) below).
4. **Pod starts, three containers:**
   - `spiffe-helper` connects to the Workload API over the CSI-mounted
     socket, requests a JWT-SVID with **audience `openbao`** (audiences
     scope who a JWT-SVID is valid for — this one is only meant to be
     presented to OpenBao), and writes it to
     `/shared/spiffe-jwt` (`openbao-agent-shared`, from the app container's
     and `openbao-agent`'s point of view). It keeps re-fetching in the
     background — JWT-SVIDs are short-lived.
   - `openbao-agent` runs `bao agent` with an `auto_auth` block: it watches
     that same JWT file, and as soon as it appears, POSTs it to OpenBao's
     `auth/jwt/login` with `role=team-jack-dev` (the role name is baked into
     this namespace's rendered `agent.hcl` — see step 0). It writes the
     resulting OpenBao token to `/shared/bao-token`, and — this is the part
     that makes it "zero app changes" — runs a local HTTP listener on
     `127.0.0.1:8207` that **transparently attaches that token to any
     request forwarded through it** (`api_proxy.use_auto_auth_token`).
   - The app container itself does nothing SPIFFE/OpenBao-specific. It just
     needs to know to call `http://127.0.0.1:8207/v1/kv-teams/...` instead
     of talking to OpenBao directly — the sidecar handles authentication.

**Step 0 (before any of this, per namespace, not per pod):** `teams-operator`
reconciles every namespace it manages once per poll cycle
(`ensure_openbao_access` in `teams_operator.py`). For a namespace like
`team-jack-dev`, it:
- renders `openbao-policy-templates/team.hcl` (substituting the namespace
  name) and `PUT`s it to OpenBao as ACL policy `team-team-jack-dev-policy`,
  scoped to `kv-teams/data/team-jack-dev/*` and
  `kv-teams/metadata/team-jack-dev/*`.
- renders `openbao-role-templates/team.json` and `PUT`s it as JWT auth role
  `team-team-jack-dev`, with `bound_claims: {sub:
  "spiffe://platform.local/ns/team-jack-dev/sa/*"}` and
  `token_policies: ["team-team-jack-dev-policy"]` — this is the line that
  connects "which SPIFFE IDs" to "which policy."
- renders `openbao-agentconfig-templates/{spiffe-helper.conf,agent.hcl}`
  (substituting the namespace into `agent.hcl`'s `role = "team-<ns>"` line)
  into a ConfigMap named `openbao-agent-config`, created in that namespace —
  this is the ConfigMap the pod-level volume mutation (step 1) references.

Without this having already run for a namespace, a pod's sidecars come up
but can never successfully log in (the role doesn't exist yet) or the pod
can't even start (the `openbao-agent-config` ConfigMap doesn't exist to
mount).

## Step by step: an app reading/writing a secret

Once the pod is running, from the app's point of view this is just an HTTP
call to `127.0.0.1:8207`:

```
app container                openbao-agent (same pod)              OpenBao
     │                              │                                   │
     │  POST /v1/kv-teams/data/     │                                   │
     │  team-jack-dev/foo           │                                   │
     │ ────────────────────────────►│                                   │
     │  {"data":{"key":"value"}}    │  attaches X-Vault-Token           │
     │                              │  (from the cached auto_auth token)│
     │                              │ ─────────────────────────────────►│
     │                              │                                   │ checks token's
     │                              │                                   │ policies against
     │                              │                                   │ the requested path
     │                              │◄──────────────────────────────────│
     │◄─────────────────────────────│         200 OK                    │
```

The policy check on OpenBao's side is a live lookup — it doesn't matter
whether the policy existed when the token was issued, only whether it
resolves to real content *at request time* (see
[Gotcha 2](#gotcha-2-policy-name-the-role-points-at-must-actually-exist)).
That's why fixing a stale/missing policy doesn't require pods to
re-authenticate — the next request just starts working.

**The isolation guarantee**: a pod in `team-jack-dev` can only ever get a
token scoped to `team-team-jack-dev-policy`, because its SPIFFE ID
(`spiffe://platform.local/ns/team-jack-dev/sa/...`) only matches the
`team-team-jack-dev` role's `bound_claims`. It cannot construct a JWT-SVID
claiming to be a different namespace — that claim comes from SPIRE, based on
where the pod is actually running, not from anything the pod supplies.
Verified live: the same pod that could read/write its own namespace's path
got a `403 permission denied` reading `team-jack-default`'s path.

## teams-operator's own access: the same pattern, one level up

`teams-operator` needs to call OpenBao's admin API (to write the
policies/roles/ConfigMaps above) — which means it needs OpenBao access
*before* any of the per-namespace machinery it's responsible for exists.
Rather than invent a second credential type, it uses the exact same
trust chain, just with a more privileged role:

- Its own Deployment
  (`apps/developer-control/teams-operator/manifests/deployment.yaml`) has
  the `csi.spiffe.io` volume and a `spiffe-helper` sidecar added **by hand**
  (not via the tenant-guardrails mutations — `engineering-platform` isn't a
  `team-*` namespace, so those mutations don't match it).
- Its SPIFFE ID is `spiffe://platform.local/ns/engineering-platform/sa/teams-operator`
  — issued automatically by the same fallback `ClusterSPIFFEID` every other
  pod gets.
- A role `teams-operator-admin` (bootstrapped once, manually, with the
  OpenBao root token — see `bootstrap/README.md`; this is the one
  unavoidable chicken-and-egg step, since the operator can't create its own
  role before it exists) grants a policy that can manage `sys/policies/acl/team-*`
  and `auth/jwt/role/team-*` — enough to administer every tenant namespace's
  access, nothing more.
- Unlike tenant pods, `teams-operator` doesn't run an `openbao-agent`
  sidecar/proxy — it needs to POST arbitrary policy/role JSON bodies, not
  just do KV reads/writes, so `teams_operator.py` itself reads the JWT file
  and calls OpenBao's HTTP API directly (`_openbao_login` /
  `_openbao_request` in `teams_operator.py`).

## Where things live

| Concern | Location |
|---|---|
| SPIRE itself, trust domain, fallback identity rule | `apps/security/spire/application.yaml`, `apps/security/spire-crds/` |
| OIDC discovery provider (JWKS for JWT-SVID validation) | Deployed by the SPIRE chart; `spire-spiffe-oidc-discovery-provider` in `spire-server` namespace |
| OpenBao itself (KV mount, jwt auth method config) | `apps/security/openbao/`; one-time bootstrap in `bootstrap/README.md` |
| CSI volume + sidecar injection for tenant pods | `apps/security/tenant-guardrails/manifests/openbao-spiffe-volume-{deployment,rollout}.yaml`, `openbao-sidecar-{deployment,rollout}.yaml` |
| Per-namespace policy/role/agent-config reconciliation | `ensure_openbao_access` in `platform-idp/teams-management/teams-operator/teams_operator.py` |
| Policy/role/agent-config templates (the actual text OpenBao/the sidecars receive) | `apps/developer-control/teams-operator/manifests/openbao-{policy,role,agentconfig}-templates/` |
| teams-operator's own privileged trust | `apps/developer-control/teams-operator/manifests/deployment.yaml` (spiffe-helper sidecar), `bootstrap/README.md` (one-time role bootstrap) |
| Sidecar image mirroring into Harbor | `apps/integration-delivery/harbor-replication/manifests/sidecar-images{.txt,-job.yaml}` |
| Opt-in label (add to a workload's own `metadata.labels` to get access) | `platform.example.com/openbao-access: "true"` — example usage: `demo-api-go/deploy/demo-api-go.yaml` |

## Why a label, not an annotation

The natural instinct for an opt-in flag is an annotation. Gatekeeper's
`Assign` mutation type can't do that, though — its `match` field only
supports `labelSelector` (matching the target object's own labels),
`namespaceSelector`, `namespaces`/`excludedNamespaces`, `kinds`, and `name`;
there's no annotation-based selector (confirmed against the live `Assign`
CRD schema: `kubectl get crd assign.mutations.gatekeeper.sh -o
jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.match.properties}'`).

The other candidate was `parameters.pathTests`, which can assert a path
`MustExist`/`MustNotExist` — but Gatekeeper requires every `pathTests`
`subPath` to be a *prefix* of the mutation's own `location`. Since
`location` here is `spec.template.spec.volumes[...]` /
`spec.template.spec.containers[...]`, a `pathTests` entry can only check
other volumes/containers, never an unrelated field like
`metadata.annotations`. Verified empirically (a `pathTests` entry pointing
at `metadata.annotations.foo` is rejected outright at `kubectl apply` time
with "all subpaths must be a prefix of the `location` value") before
settling on `labelSelector`.

So: **a label on the Deployment/Rollout's own `metadata.labels`** is the
only mechanism `Assign` actually offers for conditional injection. All four
`openbao-*.yaml` mutation files gate on it independently (not one shared
check), so there's no ordering dependency between the volume mutations and
the sidecar mutations — a workload either has the label and gets all of it,
or doesn't and gets none of it.

## Gotchas hit while building this (worth knowing, not obvious from the code alone)

### Gotcha 1: mutation, then validation order

Gatekeeper's mutating webhooks run before its validating ones. A tenant
namespace's `tenant-images-from-harbor` constraint checks *every* container
in the final pod spec — including ones Gatekeeper itself just injected. The
sidecar images (`ghcr.io/spiffe/spiffe-helper`, `quay.io/openbao/openbao`)
got rejected the first time this was tested against a real pod, because
public-registry images aren't allowed in tenant namespaces. Fixed by
mirroring both into Harbor via a declarative replication policy
(`sidecar-images-job.yaml`) and pointing the mutations at the Harbor copies.
**Lesson**: anything a mutation injects into a tenant pod is subject to
every other tenant policy, same as if the app had written it itself.

### Gotcha 2: policy name the role points at must actually exist

`ensure_openbao_access` originally wrote the ACL policy to
`sys/policies/acl/team-<namespace>` (no suffix), while the role template's
`token_policies` referenced `team-<namespace>-policy` (with suffix).
OpenBao does **not** validate at role-write time that referenced policies
exist — a token can be issued carrying a policy name that resolves to
nothing, and every request against it just gets a `403`, with no error
anywhere pointing at the actual cause. This was caught by testing an actual
read/write, not by reading the code — `bao token lookup` showed the
"right" policy name attached; only `bao policy list` revealed it was
stored under a different name. Fixed by making the write path match the
name the role references.

### Gotcha 3: JWT-SVID refresh cadence vs. token TTL

On a long-idle test pod (~6.5 hours), `spiffe-helper` only refreshed the
JWT-SVID file twice, and the gap between refreshes ended up longer than the
JWT-SVID's own validity window — so `openbao-agent`'s next login attempt
failed with `invalid expiration time (exp) claim: token is expired`. A
freshly-restarted pod worked immediately. Not fixed (no tenant workload has
hit this in practice), but worth knowing if `openbao-agent` logs start
showing that specific error on a pod that's been running a long time —
it means the SVID it's holding has gone stale, and the fix is tuning
`spiffe-helper`'s refresh interval relative to OpenBao's `token_ttl`
(currently 15m) / `token_max_ttl` (currently 1h) in
`openbao-role-templates/team.json`.

## How to check this yourself on a running pod

```sh
# Confirm all three containers are up
kubectl get pod <pod> -n <team-namespace> -o jsonpath='{range .status.containerStatuses[*]}{.name}{": "}{.ready}{"\n"}{end}'

# Confirm spiffe-helper actually got an SVID
kubectl logs <pod> -n <team-namespace> -c spiffe-helper --tail=20

# Confirm openbao-agent logged in
kubectl logs <pod> -n <team-namespace> -c openbao-agent --tail=30

# What does the resulting token actually carry?
kubectl exec <pod> -n <team-namespace> -c openbao-agent -- sh -c \
  'TOK=$(cat /shared/bao-token); BAO_ADDR=http://127.0.0.1:8207 BAO_TOKEN=$TOK bao token lookup'

# Try a real read/write through the proxy, the same way an app would
kubectl exec <pod> -n <team-namespace> -c openbao-agent -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8207 bao read kv-teams/data/<team-namespace>/<path>'
```
