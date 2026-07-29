# Bootstrap orchestration. Run from platform-infra/bootstrap/.
# Targets are added step by step — keep each one small and idempotent.

# Path to the sibling platform-base checkout (the Terraform for the kind
# cluster + Argo CD). Override on the command line if your layout differs:
#   make apply PLATFORM_BASE=/path/to/platform-base
PLATFORM_BASE ?= ../../platform-base
TF            := terraform -chdir=$(PLATFORM_BASE)

.DEFAULT_GOAL := help
.PHONY: help init apply destroy secrets

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

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

bootstrap: apply secrets ## Bootstrap the cluster (platform-base + platform-infra)
	$(MAKE) apply
	$(MAKE) secrets