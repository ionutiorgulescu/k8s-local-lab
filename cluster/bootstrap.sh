#!/usr/bin/env bash
# Rebuilds the whole lab, GitOps style. The script only does what Argo CD can't do for
# itself; everything else (metrics-server, Envoy Gateway, the GatewayClass, the shop app)
# comes from this repository's main branch on GitHub, deployed by Argo CD.
#
#   ./cluster/bootstrap.sh
#
# Steps: kind cluster -> Cilium -> Argo CD -> namespace + DB password -> root Application
#        -> wait until every Application is Synced and Healthy -> smoke test through the
#        gateway.
#
# The shop-api image isn't built here: CI (.github/workflows/shop-api.yml) publishes it to
# GHCR and writes its tag into charts/shop/values-local.yaml; the nodes pull it from there.
#
# Safe to re-run: every step skips work that's already done or is idempotent.
# Written for the bash 3.2 that ships with macOS (no bash 4 features).

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (keep in sync with cluster/README.md). The versions of everything
# Argo CD deploys are pinned in gitops/apps/*.yaml instead.
# ---------------------------------------------------------------------------
CLUSTER_NAME=lab                       # must match "name:" in cluster/kind.yaml
CILIUM_VERSION=1.20.5
ARGOCD_CHART_VERSION=10.19.0           # Argo CD v3.6.2
NAMESPACE=shop
APPS_TIMEOUT_SECONDS=900               # how long to wait for all Applications

# Run from the repo root, wherever the script is called from.
cd "$(dirname "$0")/.."

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# retry <attempts> <seconds between> <command...>
# For things that don't exist yet right after creation (e.g. a Deployment that a
# controller creates a few seconds after we apply something).
retry() {
  local attempts=$1 delay=$2 i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@" >/dev/null 2>&1; then return 0; fi
    sleep "$delay"
  done
  "$@"   # last try, showing its error
}

# Use a private, empty Helm configuration for this script. Your global Helm repos
# (and their cache) can't break or change the result: in Phase 2, a stale cache for
# an unrelated repo made `cilium install` fail.
HELM_TMP=$(mktemp -d)
export HELM_CONFIG_HOME="$HELM_TMP/config"
export HELM_CACHE_HOME="$HELM_TMP/cache"
export HELM_DATA_HOME="$HELM_TMP/data"

PF_PID=""
cleanup() {
  if [ -n "$PF_PID" ]; then kill "$PF_PID" 2>/dev/null || true; fi
  rm -rf "$HELM_TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
step "Checking prerequisites"
# ---------------------------------------------------------------------------
for tool in docker kind kubectl helm cilium openssl curl git; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed"
done
docker info >/dev/null 2>&1 || die "Docker isn't running"

mem_bytes=$(docker info --format '{{.MemTotal}}')
if [ "$mem_bytes" -lt 6000000000 ]; then
  info "Warning: Docker has $((mem_bytes / 1024 / 1024)) MiB of memory; 8 GiB is recommended."
fi

# Argo CD deploys what's on GitHub's main, not this working copy. Warn if they differ
# (compared with the last fetch of origin/main; run `git fetch` for a fresh comparison).
if ! git diff --quiet HEAD -- gitops charts 2>/dev/null; then
  info "Warning: uncommitted changes in gitops/ or charts/. Argo CD won't see them."
fi
ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "?")
if [ "$ahead" != "0" ]; then
  info "Warning: $ahead local commit(s) not on origin/main. Argo CD deploys GitHub's main: push first."
fi
info "All tools found."

# ---------------------------------------------------------------------------
step "kind cluster '$CLUSTER_NAME'"
# ---------------------------------------------------------------------------
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  info "Already exists, skipping."
else
  kind create cluster --config cluster/kind.yaml
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# ---------------------------------------------------------------------------
step "Cilium $CILIUM_VERSION with Hubble Relay"
# ---------------------------------------------------------------------------
# Not managed by Argo CD: without a CNI no pod gets an IP, Argo CD's included. Nodes
# stay NotReady until it's installed (the kind config disables the default CNI).
if helm status cilium -n kube-system >/dev/null 2>&1; then
  info "Already installed, skipping."
else
  cilium install --version "$CILIUM_VERSION" --set hubble.relay.enabled=true
fi
cilium status --wait --wait-duration 5m >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# ---------------------------------------------------------------------------
step "Argo CD (chart $ARGOCD_CHART_VERSION)"
# ---------------------------------------------------------------------------
helm upgrade --install argocd argo-cd \
  --repo https://argoproj.github.io/argo-helm \
  --version "$ARGOCD_CHART_VERSION" \
  -n argocd --create-namespace \
  -f gitops/argocd/values.yaml \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
step "Namespace '$NAMESPACE' and database password"
# ---------------------------------------------------------------------------
# The namespace is managed by the platform Application (wave 1), but the password Secret
# isn't in Git and must exist before the app starts, so create the namespace now. Argo CD
# adopts it later.
kubectl apply -f gitops/platform/namespace-shop.yaml

# Create the password only if it doesn't exist. Never replace it on a re-run:
# Postgres sets the password once, when it first initializes its data directory,
# so a new Secret wouldn't match an existing database and the API couldn't log in.
if kubectl -n "$NAMESPACE" get secret postgres-credentials >/dev/null 2>&1; then
  info "Secret postgres-credentials already exists, keeping it."
else
  kubectl -n "$NAMESPACE" create secret generic postgres-credentials \
    --from-literal=password="$(openssl rand -base64 24)"
fi

# ---------------------------------------------------------------------------
step "Root Application: hand over to Git"
# ---------------------------------------------------------------------------
# The last thing applied by hand. From here, Argo CD creates every Application in
# gitops/apps/ (sync waves: projects -1, add-ons 0, platform 1, shop 2).
kubectl apply -f gitops/root.yaml

# ---------------------------------------------------------------------------
step "Waiting for every Application to be Synced and Healthy"
# ---------------------------------------------------------------------------
# Expected: one per Application manifest in gitops/apps/, plus root.
expected=$(( $(grep -l '^kind: Application$' gitops/apps/*.yaml | wc -l) + 1 ))
deadline=$(( SECONDS + APPS_TIMEOUT_SECONDS ))
while :; do
  states=$(kubectl -n argocd get applications \
    -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' \
    2>/dev/null || true)
  total=$(printf '%s' "$states" | grep -c . || true)
  ready=$(printf '%s\n' "$states" | grep -c '^Synced/Healthy$' || true)
  printf '\r    %s of %s Applications Synced and Healthy (waiting for %s)   ' \
    "$ready" "$total" "$expected"
  if [ "$total" -ge "$expected" ] && [ "$ready" -eq "$total" ]; then
    echo
    break
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo
    kubectl -n argocd get applications
    die "Applications not all Synced and Healthy after ${APPS_TIMEOUT_SECONDS}s (see above; 'argocd app get <name>' shows why)"
  fi
  sleep 5
done
kubectl -n argocd get applications

# ---------------------------------------------------------------------------
step "Smoke test through the gateway"
# ---------------------------------------------------------------------------
# Envoy Gateway creates the proxy Deployment and Service a few seconds after the
# Gateway exists, so wait for them to appear first.
GW_SELECTOR="gateway.envoyproxy.io/owning-gateway-name=web,gateway.envoyproxy.io/owning-gateway-namespace=$NAMESPACE"
retry 30 2 kubectl -n envoy-gateway-system get svc -l "$GW_SELECTOR" -o name
retry 30 2 kubectl -n envoy-gateway-system wait --for=condition=Available deploy \
  -l "$GW_SELECTOR" --timeout=10s
ENVOY_SVC=$(kubectl -n envoy-gateway-system get svc -l "$GW_SELECTOR" \
  -o jsonpath='{.items[0].metadata.name}')

LOCAL_PORT=18888
kubectl -n envoy-gateway-system port-forward "svc/$ENVOY_SVC" "$LOCAL_PORT:80" >/dev/null 2>&1 &
PF_PID=$!
# Detach it from the shell's job list, so stopping it on exit doesn't print "Terminated".
disown "$PF_PID"

status=""
for i in $(seq 1 30); do
  status=$(curl -s -o /dev/null -m 2 -w '%{http_code}' \
    -H "Host: shop.local" "localhost:$LOCAL_PORT/api/products" || true)
  [ "$status" = "200" ] && break
  sleep 2
done
[ "$status" = "200" ] || die "GET /api/products through the gateway returned '$status'"

info "GET /api/products -> 200:"
info "$(curl -s -H 'Host: shop.local' "localhost:$LOCAL_PORT/api/products")"

step "Done"
cat <<EOF
    Nodes:      $(kubectl get nodes --no-headers | wc -l | tr -d ' ') Ready
    App:        $(kubectl -n "$NAMESPACE" get deploy api -o jsonpath='{.status.readyReplicas}') API replicas ready

    Argo CD UI:
      kubectl -n argocd port-forward svc/argocd-server 8080:80   # http://localhost:8080
      argocd admin initial-password -n argocd                    # first login as admin
    Argo CD CLI:
      export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
      argocd login --username admin

    Call the API:
      kubectl -n envoy-gateway-system port-forward svc/$ENVOY_SVC 8888:80
      curl -H "Host: shop.local" localhost:8888/api/products
EOF
