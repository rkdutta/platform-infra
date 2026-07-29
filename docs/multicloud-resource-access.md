# Self-Service Multicloud Resource Access — Trust Architecture

A developer asks for a cloud resource (an S3 bucket, a DynamoDB table, an
Azure SQL database) **and** for their app to be able to use it — and the
platform does all the heavy lifting: it provisions the resource, wires up the
authorization, and delivers **short-lived, resource-scoped credentials to the
workload with no static secret anywhere.** No access key in a Kubernetes
Secret, no connection string baked into an image, no IAM/AAD knowledge
required of the developer.

This is the same ethos as [SPIFFE-Authenticated OpenBao
Access](./openbao-spiffe-access.md), extended out of the cluster and into AWS
and Azure. This doc is the **design/target architecture** — see [Status](#status)
for what is actually built today (short version: only Crossplane core is
installed; everything below is the plan).

> **The one reframe that drives everything here:** provisioning a bucket is
> trivial. The valuable, hard part — the thing the platform must own — is
> *authorizing a specific workload to talk to that resource with credentials
> it never has to see or manage.* The unit of self-service is therefore not a
> *resource*, it is a **resource + a bound workload identity**. We call that a
> `ResourceAccess`.

---

## Design principles

Everything below follows from four rules, applied without exception:

1. **Identity by attestation, not by possession.** A workload proves who it
   is by *what it demonstrably is* (its node, namespace, ServiceAccount —
   verified by SPIRE), never by *holding a secret*. This is already true
   inside the cluster; we extend it to the cloud.
2. **No standing credentials.** Every credential is minted **just-in-time**
   and **expires on its own**. Short-lived at every hop: SVIDs (≤1h), STS /
   Entra tokens (minutes), dynamic DB creds (per-lease).
3. **Least privilege, per resource.** An identity is scoped to *exactly* the
   one bucket / table / database it needs — resource ARN or database name, not
   a wildcard.
4. **Assume breach.** Blast radius is contained by short lifetimes, per-
   namespace isolation, and per-resource scoping; every mint is audited.

The honest consequence of taking "secret zero" seriously: **you never reach
literally zero secrets — trust has to bottom out somewhere.** The discipline
is about *where* it bottoms out. See [Where trust bottoms
out](#where-trust-bottoms-out).

---

## The common root: SPIRE identity, one HSM-backed CA

Both clouds hang off a single root of trust, so that "multicloud" means one
identity federated two ways — not two parallel credential systems.

```
              AWS Private CA (ACM PCA)         ← root of trust
              key in HSM, never exported
                       │
     ┌─────────────────┴──────────────────┐
     │ (SPIRE aws_pca UpstreamAuthority)   │ (registered as
     ▼                                     │  Roles Anywhere
   SPIRE  ── issues short-lived SVIDs ──┐  │  trust anchor)
   (trust domain: platform.local)       │  │
     │  by attestation, no secrets       │  │
     ▼                                   ▼  ▼
   workloads & OpenBao            AWS trusts exactly the
   spiffe://platform.local/       identities SPIRE issues
     ns/<ns>/sa/<sa>
```

- **SPIRE** (`apps/security/spire/`) is already the cluster's identity
  provider. Trust domain `platform.local`; every pod's SPIFFE ID is templated
  as `spiffe://platform.local/ns/<namespace>/sa/<serviceaccount>`.
- Back SPIRE with **AWS Private CA (ACM PCA)** as its
  `UpstreamAuthority`. The CA private key then lives in AWS's HSM and is
  **never exportable**. This same CA is what AWS trusts (below), so AWS
  natively trusts SPIRE-issued certs.
- SPIRE issues two credential flavors, and **we use a different one per
  cloud**:
  - **X.509-SVID** (a short-lived cert, proof-of-possession) → AWS.
  - **JWT-SVID** (a short-lived bearer JWT) → Azure.

---

## Two clouds, two federation mechanisms

The principle is identical for both clouds; the last-hop handshake is not,
because **AWS and Azure expose different trust primitives.** This asymmetry is
real, but it lives *inside the platform* — developers never see it.

| | **AWS** | **Azure** |
|---|---|---|
| SPIRE credential | **X.509-SVID** | **JWT-SVID** |
| Cloud-side trust | **IAM Roles Anywhere** — trust anchor = our ACM PCA | **Entra Workload Identity Federation** — federated credential on an app registration |
| Trust model | CA trust anchor: trusts anything the CA signs | OIDC issuer trust: trusts tokens from our issuer |
| Token type | X.509 → **proof-of-possession** (not replayable) | JWT → **bearer** (usable by any holder until expiry) |
| Public endpoint needed? | **No** — workload calls out, cert-based | **Yes** — Entra must fetch our public JWKS |
| Scoping | role/profile matched on cert SAN (the SPIFFE ID) | federated credential matched on issuer + subject (the SPIFFE ID) |

### AWS — X.509-SVID → IAM Roles Anywhere

AWS has a purpose-built primitive for authenticating workloads that live
*outside* AWS: **IAM Roles Anywhere**. You register a CA as a **trust
anchor**; any workload presenting a certificate that chains to that CA can
call **out** to Roles Anywhere and exchange the cert for short-lived AWS
credentials.

```
1. Register the ACM PCA as the Roles Anywhere trust anchor   (one-time, AWS side)
2. Workload (or OpenBao) holds its SPIRE X.509-SVID          (no static key)
3. It calls Roles Anywhere, presenting the cert
4. AWS: "chains to the CA I trust? SAN matches an allowed SPIFFE ID?" → yes
5. AWS returns short-lived credentials scoped to a narrow IAM role
```

- **No inbound reachability.** The workload initiates; AWS never reaches into
  the cluster. This is exactly why Roles Anywhere fits a local `kind` cluster
  where OIDC-based federation (IRSA) does not.
- **Proof-of-possession.** Each request is signed with the SVID's private
  key, so a stolen token is not replayable — stronger than a bearer token.
- The SPIFFE ID is carried in the cert's URI SAN, so a Roles Anywhere
  profile can map a *specific* SPIFFE ID to a *specific* IAM role — trust is
  "this workload," not "someone from this cluster."

### Azure — JWT-SVID → Entra Workload Identity Federation

Azure has **no CA-trust-anchor equivalent** for workload credentials. Its
mechanism is OIDC: configure a **federated identity credential** on an Entra
app registration (or managed identity) that trusts
*"JWTs from issuer `<SPIRE OIDC discovery URL>` with subject `<SPIFFE ID>`."*

```
1. Create an Entra app registration + federated identity credential   (one-time)
     issuer  = https://<public SPIRE OIDC discovery endpoint>
     subject = spiffe://platform.local/ns/<ns>/sa/<sa>
2. Workload (or OpenBao) presents its SPIRE JWT-SVID
3. Entra validates the JWT — fetching our public JWKS to check the signature
4. Entra returns an Azure access token scoped to a narrow role assignment
```

**The one catch you must design for:** to validate the JWT, **Entra fetches
SPIRE's OIDC discovery + JWKS over the public internet.** This is the wall we
dodged on AWS with Roles Anywhere; Azure cannot dodge it. So Azure *requires*
SPIRE's OIDC discovery provider (`spire-spiffe-oidc-discovery-provider`) to be
**publicly reachable**.

- This is **not a secret exposure.** JWKS contains only *public* signing
  keys — it is *designed* to be fetched by any relying party. Every OIDC
  provider serves it publicly. The cost is **operational** (a public HTTPS
  endpoint: real ingress + DNS on a proper cluster, a `cloudflared`-style
  tunnel on a laptop), not a security downgrade. Lock the exposure to
  `/.well-known/openid-configuration` and the keys path only.
- **Azure is bearer, not proof-of-possession** — that is Azure's ceiling, not
  a flaw in the design. Mitigate with very short JWT-SVID TTLs, a tight
  `audience` claim, and Conditional Access policies on the app registration.
- **Cert-based fallback (weaker, avoid unless forced):** an Entra app can
  authenticate with a client *certificate* instead, which is outbound and
  needs no public endpoint — but Entra pins certs by thumbprint rather than
  trusting a CA, which fights SPIRE's hourly leaf rotation and forces a
  longer-lived held cert. Only use this if you genuinely cannot expose the
  JWKS endpoint.

### A multicloud fork worth noting

Because **Azure forces a public JWKS endpoint regardless**, Roles Anywhere's
"no public endpoint" advantage for AWS partly evaporates once you're
multicloud. Two defensible designs:

- **Per-cloud-optimal (recommended):** AWS via Roles Anywhere (keep the
  proof-of-possession strength — essentially free), Azure via OIDC. Two
  mechanisms, AWS stays stronger.
- **Symmetric/simpler:** OIDC for *both* clouds (AWS also supports OIDC web
  identity). One mechanism, one public JWKS endpoint for both — at the cost of
  giving up AWS's PoP advantage and making both clouds bearer.

We take **per-cloud-optimal** and hide the asymmetry behind the
`ResourceAccess` abstraction.

---

## Where OpenBao fits: databases and brokering

Federation gets a workload short-lived credentials to *cloud APIs* (S3,
DynamoDB, ...). **Databases are different** — a role does not produce a
database *login*. This is where OpenBao's secrets engines do the heavy
lifting, over the SPIFFE→OpenBao path the platform already has:

- **Database secrets engine (dynamic):** OpenBao connects to the database as
  admin and, per lease, **creates an ephemeral DB user** with exactly the
  grants specified (`creation_statements`), valid for a short TTL, then
  auto-revokes it. The app reads `database/creds/<ns>-<db>` via its existing
  SPIFFE identity and gets a fresh scoped login. This is **per-lease, not
  per-query** — the app fetches once (typically via an OpenBao Agent sidecar),
  uses the credential for the whole lease across its connection pool, and
  refreshes before expiry.
- **Database secrets engine (static):** a variant that manages **one fixed DB
  user** and just **rotates its password** on a schedule — no user churn, no
  standing secret. Better for pooled, chatty apps. A per-catalog-entry choice.

**Crucially, OpenBao itself holds no static cloud master key.** OpenBao
authenticates *to the cloud* the same way workloads do — via its own SPIRE
identity (X.509-SVID → Roles Anywhere for AWS; JWT-SVID → Entra federation for
Azure, e.g. to become the AAD admin on an Azure SQL server). The trust
question is simply asked one level up, and answered the same way.

---

## The developer-facing abstraction

Developers do **not** see IAM, Roles Anywhere, Entra, trust anchors, or
OpenBao roles. They declare a **binding** — *"my app needs this access to this
resource"* — and the platform routes it to whichever mechanism fits.

```yaml
kind: ResourceAccess              # the catalog XRD
spec:
  resource:
    type: bucket                  # bucket | table | sqlinstance | ...
    name: uploads
    region: eu-west-1
  access:
    workload: my-api              # the app (its ServiceAccount / SPIFFE ID) in this namespace
    permission: readwrite         # readonly | readwrite
```

Behind that one object, the platform picks the mechanism per resource kind:

| Resource | Access mechanism | Why |
|---|---|---|
| S3 / DynamoDB / SQS (object & API) | X.509-SVID → **Roles Anywhere** → scoped IAM role | roles are the native, correct grant here |
| Azure Blob / cloud APIs | JWT-SVID → **Entra federation** → scoped role assignment | Azure's workload-identity path |
| Postgres / MySQL / Azure SQL (databases) | **OpenBao DB secrets** (dynamic user or rotated password) | a role does not produce a DB login |

---

## Responsibility split

The design keeps each component doing what it is best at — mirroring how the
platform already splits work (Crossplane-style declarative cloud state;
`teams-operator` owning all OpenBao and per-namespace wiring):

```
Developer  ──request──▶ teams-api        "app my-api wants readwrite to bucket uploads"
teams-api            ──▶ teams-operator (reconcile loop)
                          │
  ┌── Crossplane owns the cloud resource ───────────────────────────┐
  │   materialize the XR → provision the bucket / DB                 │
  │   write connection details (ARN, DB host/port) to the namespace  │
  └──────────────────────┬───────────────────────────────────────────┘
                          │
  ┌── teams-operator owns the access wiring ─────────────────────────┐
  │   AWS:   Roles Anywhere profile + IAM role scoped to the ARN,     │
  │          trusting this namespace's SPIFFE ID                      │
  │   Azure: Entra federated credential + role assignment             │
  │   DB:    OpenBao database role (creation SQL) scoped to the DB    │
  │   extend this namespace's OpenBao policy / SPIFFE binding         │
  └──────────────────────┬───────────────────────────────────────────┘
                          │
App in ns ─SPIRE SVID─▶ (Roles Anywhere | Entra | OpenBao) ─▶ short-lived
                          scoped creds ─▶ talks to the resource
```

- **Crossplane** = cloud resource desired state. (Core installed at
  `apps/resource/crossplane/`; providers/compositions are the next layers —
  see [Repo layout](#repo-layout).)
- **teams-operator** = all identity/access wiring (IAM/Entra + OpenBao),
  reading the resource's identifiers from Crossplane's connection output. This
  extends the existing per-namespace OpenBao programming
  (`ensure_openbao_access` / `delete_openbao_access`).
- **The app** = uses the SPIRE→(cloud|OpenBao) path it already has. No code
  change to its identity mechanism.

**Teardown mirrors the OpenBao-cleanup discipline already established:**
deleting the `ResourceAccess` (or the namespace/project) tears down *both* the
Crossplane resource *and* every access artifact (IAM role, Roles Anywhere
profile, Entra credential, OpenBao role). Orphaned cloud resources cost money
and orphaned trust grants are a security hole — teardown is a first-class,
verified step, not an afterthought.

---

## Where trust bottoms out

After all of the above, the irreducible roots are:

1. **The ACM Private CA key** — in AWS's HSM, non-exportable, the anchor both
   SPIRE and AWS trust.
2. **SPIRE's node/workload attestation** — the cluster facts SPIRE uses to
   decide a pod *is* a given SPIFFE ID (k8s PSAT for nodes; namespace +
   ServiceAccount selectors for workloads). No secret is distributed to
   workloads; identity is a *property*, verified.
3. **A human operator with a hardware MFA key**, used **once** at bootstrap to
   create the ACM PCA, register the Roles Anywhere trust anchor, and configure
   the Entra app registrations. That human is the true "secret zero" — offline,
   hardware-backed, human-gated, and **never on the runtime path**.

There is **no long-lived, network-reachable, exportable secret** in the
runtime path. That is the goal, and it is achievable — that is why this design
is worth the extra machinery.

### Hardening OpenBao's own secret zero

Today OpenBao's deepest secret zero is its **Shamir unseal shares** in
`bootstrap/init-keys.json` (git-ignored). A security review flags this first.
The target: **auto-unseal via AWS KMS**, where OpenBao's pod gets its SPIRE
cert from the agent *before* it is unsealed (attestation does not depend on
seal state), uses that cert through Roles Anywhere to reach KMS, and KMS
unwraps the unseal key. **No shares on disk.** Recovery keys are kept offline
(HSM / split among officers) for break-glass only, never on the runtime path.

---

## Audit & verification (assume breach)

- Every request is verified **explicitly** at each hop — OpenBao policy checks
  the SPIFFE ID; Roles Anywhere checks the cert chain + SAN; Entra checks the
  issuer + subject; the DB grant is scoped in SQL. Three independent checks,
  none based on network location.
- Turn on the **OpenBao audit device**, **CloudTrail** on Roles Anywhere /
  STS / KMS, and **Entra sign-in logs**, before opening the catalog to
  developers. Attestation-based identity makes these logs meaningful — every
  line ties to a specific workload identity. Alert on anomalous minting (a
  workload requesting creds it has never requested before).

---

## Repo layout

Crossplane is organized as a layered stack under `apps/resource/`, one Argo CD
Application per layer, ordered by sync-wave (a layer only works once the layer
below it is Healthy):

```
apps/resource/
├── crossplane/              wave 0  core engine + Provider/Composition CRDs   [installed]
├── crossplane-providers/    wave 1  provider packages (bring cloud CRDs)      [planned]
├── crossplane-runtime/      wave 2  Functions + ProviderConfigs (creds)        [planned]
└── crossplane-catalog/      wave 3  XRDs + Compositions = the ResourceAccess API [planned]
```

Credentials/config that must not live in git (the ACM PCA references, Entra
app IDs, any bootstrap material) are seeded out-of-band, following the same
pattern as `bootstrap/enable-oidc-sso.sh` and the git-ignored
`bootstrap/init-keys.json`.

---

## Status

- **Installed:** Crossplane core `2.3.4` (`apps/resource/crossplane/`,
  Synced/Healthy).
- **Not yet built:** everything else in this doc — providers, ProviderConfigs,
  the ACM PCA ↔ SPIRE ↔ Roles Anywhere wiring, the Entra federation, the
  `ResourceAccess` XRD/Compositions, the `teams-operator` access-wiring
  reconcile step, KMS auto-unseal, and the teams-api/teams-app request path.
  This document is the **design** those pieces will be built against.

## Suggested build order

1. Stand up **ACM Private CA**; make it SPIRE's `UpstreamAuthority`.
2. Register that CA as the **Roles Anywhere trust anchor**; define one
   narrowly-scoped IAM role + profile.
3. Expose SPIRE's **OIDC discovery** publicly; create the first **Entra**
   app registration + federated identity credential.
4. Move OpenBao to **KMS auto-unseal**; get the Shamir shares off disk;
   recovery keys offline.
5. Wire the **first resource-scoped flow** end-to-end (one bucket, one
   namespace, short leases) — AWS first, then the Azure SQL equivalent.
6. Turn on **audit** (OpenBao device + CloudTrail + Entra logs) before opening
   the catalog to developers.

## Open questions

- **Per-cloud-optimal vs symmetric OIDC** (see [the fork](#a-multicloud-fork-worth-noting))
  — decided per-cloud-optimal, revisit if operational cost of two mechanisms
  proves high.
- **Dynamic vs static DB credentials** as the per-catalog-entry default.
- **How `teams-operator` configures Roles Anywhere / Entra** — directly via
  the cloud SDKs, or by having Crossplane provision the IAM/Entra objects too
  (provider-aws-iam / provider-azure) and `teams-operator` only wiring OpenBao.
  Leaning toward Crossplane owning *all* cloud-side objects (resource + IAM +
  Entra) and `teams-operator` owning *only* the OpenBao/SPIFFE side, for a
  clean split.
