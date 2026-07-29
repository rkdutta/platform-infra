# Bootstrap orchestration. Run from platform-infra/bootstrap/.
# Targets are added step by step — keep each one small and idempotent.

# Path to the sibling platform-base checkout (the Terraform for the kind
# cluster + Argo CD). Override on the command line if your layout differs:
#   make apply PLATFORM_BASE=/path/to/platform-base
PLATFORM_BASE ?= ../../platform-base
TF            := terraform -chdir=$(PLATFORM_BASE)
OPENBAO_NS    ?= openbao

.DEFAULT_GOAL := help
.PHONY: help init apply destroy secrets projects deploy-root-app openbao bootstrap

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
secrets: ## Create out-of-band secrets (repo creds, platform-tls, ghcr)
	./create-secrets.sh

projects: ## Apply all project manifests
	kubectl apply -f projects/

deploy-root-app: ## Deploy the root app (platform-infra) to the cluster
	kubectl apply -f root-app.yaml

openbao: ## Init + unseal OpenBao once it's up (runs openbao.sh; skips if already initialized)
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

bootstrap: ## Bootstrap the cluster (platform-base + platform-infra)
	$(MAKE) apply
	$(MAKE) secrets
	$(MAKE) projects
	$(MAKE) deploy-root-app
	$(MAKE) openbao