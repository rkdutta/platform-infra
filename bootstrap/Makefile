# Bootstrap orchestration. Run from platform-infra/bootstrap/.
# Targets are added step by step — keep each one small and idempotent.

# Path to the sibling platform-base checkout (the Terraform for the kind
# cluster + Argo CD). Override on the command line if your layout differs:
#   make apply PLATFORM_BASE=/path/to/platform-base
PLATFORM_BASE ?= ../../platform-base
TF            := terraform -chdir=$(PLATFORM_BASE)
OPENBAO_NS    ?= openbao
TEAMS_NS      ?= engineering-platform

.DEFAULT_GOAL := help
.PHONY: help init apply destroy check-apiserver secrets projects deploy-root-app openbao openbao-kv openbao-sso openbao-jwt openbao-access harbor-pull ratify-harbor-pull harbor-sso teams-api-access bootstrap

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── platform-base (Terraform: kind cluster, Argo CD, platform-tls, node-hosts) ──
init: ## terraform init (platform-base)
	$(TF) init

apply: init ## terraform apply (platform-base) — create/update the cluster
	$(TF) apply

destroy: ## terraform destroy (platform-base) — tear down the cluster
	$(TF) destroy

# ── platform-infra bootstrap ──
# check-apiserver guards every cluster-touching target below. After a kind
# recreate the apiserver's host port changes; a stale/not-yet-ready endpoint
# then fails fast here with a clear message instead of a confusing error deep
# inside kubectl/helm (e.g. "Kubernetes cluster unreachable: Get .../version").
check-apiserver: ## Verify the Kubernetes apiserver is reachable (waits up to ~2m; fails if the cluster is down)
	@echo ">> checking apiserver (context: $$(kubectl config current-context 2>/dev/null || echo none))"
	@i=0; until kubectl get --raw='/healthz' >/dev/null 2>&1; do \
		i=$$((i+1)); \
		if [ $$i -ge 24 ]; then \
			echo "   apiserver unreachable at $$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) — is the cluster up? try 'make apply'"; \
			exit 1; \
		fi; \
		echo "   waiting for apiserver... ($$i/24)"; sleep 5; \
	done; \
	echo "   apiserver reachable: $$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)"

secrets: check-apiserver ## Create out-of-band secrets (repo creds, platform-tls, ghcr)
	./create-secrets.sh

projects: check-apiserver ## Apply all project manifests
	kubectl apply -f projects/

deploy-root-app: check-apiserver ## Deploy the root app (platform-infra) to the cluster
	kubectl apply -f root-app.yaml

openbao: check-apiserver ## Init + unseal OpenBao once it's up (runs openbao.sh; skips if already initialized)
	@echo ">> waiting for OpenBao API in ns '$(OPENBAO_NS)' (up to 5m)..."
	@i=0; until kubectl -n $(OPENBAO_NS) exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status' 2>/dev/null | grep -q Initialized; do \
		i=$$((i+1)); [ $$i -ge 60 ] && { echo "   timed out waiting for openbao-0"; exit 1; }; \
		sleep 5; \
	done; echo "   OpenBao API is up"
	@if kubectl -n $(OPENBAO_NS) exec openbao-0 -- sh -c 'BAO_ADDR=http://127.0.0.1:8200 bao status -format=json' 2>/dev/null | grep -q '"initialized": *true'; then \
		echo ">> already initialized — skipping openbao.sh (re-running would overwrite init-keys.json)"; \
	else \
		bash openbao.sh; \
	fi

# ── OpenBao runtime access (wiped by a cluster/PVC recreate; needs `openbao`
#    init done first, plus Keycloak up for -sso and SPIRE up for -jwt) ──
openbao-kv: check-apiserver ## Enable the KV-v2 secrets engine at kv/ (idempotent)
	./enable-openbao-kv.sh

openbao-sso: check-apiserver ## Enable OpenBao human OIDC SSO login via Keycloak (idempotent)
	./enable-oidc-sso.sh openbao

openbao-jwt: check-apiserver ## Enable OpenBao SPIRE/SPIFFE workload jwt auth + operator role (idempotent; re-run to refresh a rotated SPIRE CA)
	./enable-openbao-jwt.sh

openbao-access: ## Full post-recreate OpenBao runtime bootstrap (kv mount + human SSO + workload jwt)
	$(MAKE) openbao-kv
	$(MAKE) openbao-sso
	$(MAKE) openbao-jwt

harbor-pull: check-apiserver ## Create the Harbor pull robot + imagePullSecret (needs Harbor Healthy; waits for it)
	./create-secrets.sh harbor-pull

ratify-harbor-pull: check-apiserver ## Create Ratify's own Harbor pull robot + imagePullSecret (needs Harbor Healthy; waits for it) — without this Ratify 401s resolving Harbor images (looks like "unsigned image" but isn't)
	./create-secrets.sh ratify-harbor-pull

harbor-sso: check-apiserver ## Enable Harbor OIDC login via Keycloak (idempotent; needs Harbor Healthy — waits on its rollout)
	./enable-oidc-sso.sh harbor

teams-api-access: check-apiserver ## (Re)create teams-api-k8s-access ConfigMap (apiserver URL + CA for GET /kubeconfig; wiped by cluster recreate)
	TEAMS_NS=$(TEAMS_NS) ./teams-api-access.sh

bootstrap: ## Bootstrap the cluster (platform-base + platform-infra)
	$(MAKE) apply
	$(MAKE) secrets
	$(MAKE) projects
	$(MAKE) deploy-root-app
	$(MAKE) openbao
	$(MAKE) harbor-pull
	$(MAKE) ratify-harbor-pull
	$(MAKE) harbor-sso
	$(MAKE) openbao-access
	$(MAKE) teams-api-access