# Keyless signing: the actual trust mechanics

Two questions worth answering precisely, because the common shorthand
("Rekor trusts GitHub OIDC", "Ratify checks the signature") glosses over
*which* component verifies *what*, and in what order. Grounded in
`docs/keyless-supply-chain.pdf` and the live Gatekeeper/Ratify config.

## The one-line correction

**Rekor never validates the GitHub OIDC token.** That happens exactly once,
one hop earlier, at Fulcio. Rekor's job is narrower and different: it
independently checks that the *signature cryptographically verifies against
the certificate*, then timestamps and publishes that fact forever. Rekor is
a notary, not an identity provider — it trusts math, not GitHub.

Ratify, at the other end, doesn't "believe" anything about GitHub either —
it re-derives trust from scratch, every time, from five independent checks
(below), using a **pinned identity string** as the actual anchor. Nothing is
cached, shared, or taken on faith from an earlier step.

## Phase 1 — signing (in CI, once per build)

```mermaid
sequenceDiagram
    autonumber
    participant CI as GitHub Actions<br/>(cosign)
    participant GH as GitHub OIDC<br/>token.actions.githubusercontent.com
    participant Fulcio
    participant Rekor
    participant Reg as Harbor (registry)

    Note over CI,Reg: SIGNING — no COSIGN_KEY anywhere; the private key exists for seconds
    CI->>GH: request an ID token (aud=sigstore)
    GH-->>CI: signed JWT — sub=repo:org/app,<br/>workflow=release.yml, ref=refs/heads/main
    CI->>CI: generate an ephemeral keypair<br/>(in memory only, this run)
    CI->>Fulcio: present the OIDC JWT + ephemeral public key
    Fulcio->>GH: fetch GitHub JWKS,<br/>verify the JWT signature, issuer, audience, expiry
    Note right of Fulcio: TRUST CHECK 1 — this is the ONLY place<br/>GitHub OIDC is actually validated
    Fulcio-->>CI: X.509 cert, ~10 min TTL —<br/>SAN = github.com/org/app/.github/workflows/release.yml@refs/heads/main<br/>issuer ext = token.actions.githubusercontent.com
    CI->>CI: sign the image digest with the ephemeral private key
    CI->>CI: discard the private key immediately
    CI->>Rekor: submit (signature, certificate, digest)
    Rekor->>Rekor: independently verify the signature<br/>is valid for that certificate public key
    Note right of Rekor: TRUST CHECK 2 — Rekor checks the MATH,<br/>never re-touches the OIDC token or GitHub at all
    Rekor-->>CI: Merkle inclusion proof +<br/>Signed Entry Timestamp (SET)
    CI->>Reg: push image + signature + cert +<br/>attestations (SBOM · vuln · quality · SLSA)
```

Why Rekor matters even though it doesn't check identity: the Fulcio
certificate is deliberately short-lived (~10 minutes) — there is no
long-term key to protect, but that also means the cert looks **expired** by
the time anyone checks it later. Rekor's signed, timestamped log entry is
what lets a verifier — days or months later — prove the signing happened
*while the certificate was still genuinely valid*, without trusting
anyone's clock or word for it. Remove Rekor and every signature becomes
unverifiable the moment its 10-minute certificate lapses.

## Phase 2 — verification (at cluster admission, every time)

```mermaid
sequenceDiagram
    autonumber
    participant Dev as kubectl / Argo CD
    participant GK as Gatekeeper
    participant Ratify
    participant Reg as Harbor (registry)
    participant Rekor
    participant TUF as Sigstore TUF trust root

    Note over Dev,TUF: VERIFICATION — the cert is long expired by now; Rekor is why that is fine
    Dev->>GK: create Pod, image@digest
    GK->>Ratify: verify this image (external data provider)
    Ratify->>Reg: pull signature + certificate + attestations
    Ratify->>TUF: fetch the Fulcio root CA + Rekor public key<br/>(cached, periodically refreshed — never hardcoded)
    Ratify->>Ratify: check 1 — signature is cryptographically<br/>valid against the certificate
    Ratify->>Ratify: check 2 — certificate chains to the Fulcio root CA
    Ratify->>Ratify: check 3 — cert identity ==<br/>github.com/org/app/.github/workflows/release.yml@refs/heads/main
    Note right of Ratify: TRUST CHECK 3 — this is the actual anchor.<br/>Any OTHER repo/workflow also has a valid Fulcio cert;<br/>only the PINNED identity is accepted
    Ratify->>Ratify: check 4 — issuer ext == token.actions.githubusercontent.com
    Ratify->>Rekor: verify the inclusion proof / SET
    Note right of Ratify: TRUST CHECK 4 — proves signing happened<br/>while the certificate was still genuinely valid
    Ratify->>Ratify: check 5 — required attestations<br/>(SBOM · vuln · quality · SLSA) present
    Ratify-->>GK: verified ✓ / denied ✗ — any single failure denies
    GK-->>Dev: admit or reject
```

## Who actually verifies what

| Question | Answered by | How |
|---|---|---|
| Is this really GitHub, and this exact workflow? | **Fulcio**, at sign time | Validates the OIDC JWT against GitHub's own JWKS before it will issue a cert at all |
| Is the signature mathematically valid? | **Rekor** (sign time) *and* **Ratify** (verify time), independently, both from scratch | Standard signature verification against the cert's public key |
| Did this really happen, and when? | **Rekor** | Public Merkle-tree log + its own Signed Entry Timestamp — tamper-evident, independently auditable with a bare `cosign verify`, no platform access needed |
| Is this *our* pipeline, not just *a* valid Sigstore signer? | **Ratify's pinned policy** | Exact-match on the cert's SAN identity + OIDC issuer extension — this is the actual trust anchor, not the cryptography alone |
| Can I trust Fulcio's and Rekor's own public keys? | **Sigstore TUF trust root** | A securely-updatable, multi-signer bundle Ratify fetches and caches — removes the "where does Ratify get a hardcoded public key from" bootstrapping problem |

The crux, worth stating plainly: **cryptographic validity alone proves
nothing about trust.** Any GitHub repo in the world can get a Fulcio
certificate and produce a perfectly valid signature. What makes a signature
*acceptable* is that its certificate's identity exactly matches the string
Ratify was configured to expect — `--certificate-identity` at sign time,
Ratify's trust policy at verify time. Change either side and it stops
matching; there's no key to rotate or secret to leak, only a string to keep
in sync.

## Live-state caveat

Per `keyless-supply-chain.pdf`: **signature enforcement is currently scoped
to the `ratify-demo` namespace**, not cluster-wide. The mechanism above is
real and working, but not yet the default posture for every tenant
namespace — worth confirming before presenting this as "every image in the
cluster is verified," which isn't accurate yet.

## Where things live

| Concern | File |
|---|---|
| Full CI pipeline (build → scan → sign → attest → verify → release) and admission gate list | `docs/keyless-supply-chain.pdf` |
| Component communication matrix (CI → Fulcio/Rekor, Gatekeeper → Ratify edges) | `docs/component-communication-matrix.md` |
