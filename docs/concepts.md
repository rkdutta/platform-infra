Who writes what

teams-api writes only its SQLite DB. Every mutating endpoint (create_project, delete_project, grants, GitHub connection state, etc.) goes through store.py. That's the only durable write path it has.

Keycloak — reads only, in practice. keycloak_admin.py still contains write methods (ensure_group, delete_group, assign_realm_role, add_user_to_group, ...) and main.py still calls them — but every call site is gated by KC_WRITES_ENABLED, which the live deployment manifest pins to "false". So today teams-api only reads Keycloak (user directory lookups for the assignment picker, group/role membership) via a client (teams-api-sa) scoped read-only. teams-operator is the sole Keycloak writer (reconcile_keycloak, KC_RECONCILE_ENABLED=true), authenticating with its own admin client whose secret it pulls from OpenBao over its SPIFFE identity — no static k8s Secret.

OpenBao — teams-api never touches it, not even to read. No OpenBao client exists in teams-api at all. teams-operator is the only component that talks to OpenBao (policies, JWT auth roles, identity-group aliases, secret data, and now GitHub App private keys).

GitHub — teams-api never calls the GitHub API. For the self-service GitHub App flow it only constructs redirect URLs (App-manifest creation, install picker) and records pending state from the callback (installation_id, the one-time manifest code). It explicitly never exchanges that code — the comment in main.py is blunt about it: "teams-api never holds key material." teams-operator does the exchange and writes the resulting App key to OpenBao.

Kubernetes — teams-api reads, never writes. workloads.py, provisioning_status.py, events_reader.py, app_compliance.py all call the k8s API read-only (list Rollouts/Deployments/Ingresses/etc. for the UI). No create_*/patch_*/delete_* k8s calls anywhere in teams-api. All cluster-side mutation — namespaces, RBAC, quotas, Harbor pull secrets — is teams-operator's job, as your root CLAUDE.md already states.

teams-app (browser) only calls teams-api's HTTP API — plus one direct exception: it does its own OIDC login against Keycloak in-browser via keycloak-angular (auth.service.ts), since that's how the SPA gets a user token in the first place. That's standard OIDC auth, not a platform-state write.

Doc vs. live-state diff found and fixed

platform-infra/docs/keycloak-write-ownership-and-internal-auth.md already documents this split correctly at the architecture level (teams-api read-only, teams-operator sole writer — verified true), but it had one factual error: it twice claimed "the KC_WRITES_ENABLED flag is gone." It isn't — it's still in main.py, still an explicit env var on the teams-api Deployment, just pinned to "false" as a documented rollback lever. I corrected both spots in the doc to say it still exists but is inert.


- Humans → Keycloak. Every human-facing login (teams-ui, teams-cli, OpenBao's own UI, Argo CD, Harbor) is OIDC against the teams realm.
- Machines → JWT-SVIDs (SPIRE). teams-operator, and any tenant workload opted into openbao-access, prove identity with a SPIRE-issued JWT-SVID — no static credential.
- Bootstrap-only → a raw OpenBao root token. Not SPIRE, not Keycloak — a Shamir-unseal-derived root token in bootstrap/init-keys.json, used only for the handful of one-time chicken-and-egg setup steps that have to happen before SPIRE-trust or OIDC exist yet (enabling the jwt/oidc auth methods themselves, writing the very first teams-operator-admin policy/role, seeding kv/platform/keycloak-admin). Nothing in steady-state runtime traffic uses it — it's deliberately kept out of any pod, never handed to a component, and is the thing your CLAUDE.md's "never revoke it as BAO_TOKEN" gotcha is about.

So: humans → Keycloak, machines → JWT-SVIDs, plus a root token that only exists to bootstrap those two trust chains into existence — not a third steady-state path.
