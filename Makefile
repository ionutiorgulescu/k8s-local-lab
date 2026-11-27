# Shortcuts for the commands used most. `make` (or `make help`) lists them.
# Recipes are plain shell, so you can read exactly what each one runs.

CLUSTER   := lab
CHART     := charts/shop
ENV_LOCAL := gitops/envs/local/shop.yaml
ENV_EKS   := gitops/envs/eks/shop.yaml
URL       := http://shop.localhost:8088

.DEFAULT_GOAL := help
.PHONY: help bootstrap destroy status lint template check check-api check-frontend \
        smoke argocd-ui dev-frontend

help: ## List the targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  make %-16s %s\n", $$1, $$2}'

# --- Cluster -----------------------------------------------------------------------------

bootstrap: ## Create or complete the whole lab (kind, Cilium, Argo CD; Argo CD deploys the rest)
	./cluster/bootstrap.sh

destroy: ## Delete the kind cluster (everything in it, including the database)
	kind delete cluster --name $(CLUSTER)

status: ## Nodes, Argo CD applications, and the shop pods
	@kubectl get nodes
	@echo; kubectl -n argocd get applications
	@echo; kubectl -n shop get pods -o wide

smoke: ## Call the site and the API through the gateway
	@curl -s -o /dev/null -w 'GET /              http=%{http_code}\n' $(URL)/
	@curl -s -w '\n' $(URL)/api/products
	@curl -s -w '\n' $(URL)/api/version

argocd-ui: ## Open a tunnel to the Argo CD UI on http://localhost:8080
	kubectl -n argocd port-forward svc/argocd-server 8080:80

# --- Checks (no cluster needed) ----------------------------------------------------------

lint: ## Lint the chart for each environment, check the bootstrap script's syntax
	helm lint $(CHART) -f $(ENV_LOCAL)
	helm lint $(CHART) -f $(ENV_EKS)
	bash -n cluster/bootstrap.sh

template: ## Render the chart exactly as Argo CD does for the local environment
	helm template shop $(CHART) -n shop -f $(ENV_LOCAL)

check-api: ## Install and compile the API (TypeScript)
	cd services/api && npm ci && npm run build

check-frontend: ## Install, type-check and build the frontend
	cd services/frontend && npm ci && npm run build

check: lint check-api check-frontend ## All checks: chart, script, both services

# --- Local development -------------------------------------------------------------------

dev-frontend: ## Run the frontend with hot reload on :5173, /api proxied to the cluster
	cd services/frontend && npm run dev
