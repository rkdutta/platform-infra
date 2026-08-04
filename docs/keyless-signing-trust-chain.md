# Keyless signing — sequence diagram

## Signing

```mermaid
sequenceDiagram
    CI->>GitHub: request OIDC token
    GitHub-->>CI: signed token
    CI->>Fulcio: send token and public key
    Fulcio->>GitHub: verify token
    Fulcio-->>CI: short lived certificate
    CI->>Rekor: submit signature and certificate
    Rekor-->>CI: log entry recorded
    CI->>Registry: push image and signature
```

## Verification

```mermaid
sequenceDiagram
    Gatekeeper->>Ratify: verify image
    Ratify->>Registry: pull signature and certificate
    Ratify->>Rekor: check log entry
    Ratify-->>Gatekeeper: allowed or denied
```

- Fulcio is the only step that checks the GitHub token. It issues a short
  lived certificate instead of a long lived key.
- Rekor does not check GitHub. It only checks that the signature matches
  the certificate, then records the entry publicly.
- Ratify does not trust GitHub either. It checks the signature, checks the
  certificate identity against an allow list, and checks Rekor for the log
  entry.
