#!/usr/bin/env bash
# Rebuilds the whole Phase 2 lab from the repo: kind cluster, Cilium + Hubble,
# metrics-server, Envoy Gateway, the shop-api image, and the shop Helm chart.
#
#   ./cluster/bootstrap.sh
#
# Safe to re-run: every step either skips work that's already done or is an
# idempotent "apply" / "helm upgrade --install".
#
# Written for the bash 3.2 that ships with macOS (no bash 4 features).

set -euo pipefail

# ---------------------------------------------------------------------------
# Pinned versions (keep in sync with cluster/README.md)
# ---------------------------------------------------------------------------
CLUSTER_NAME=lab                       # must match "name:" in cluster/kind.yaml
CILIUM_VERSION=1.20.5
METRICS_SERVER_CHART_VERSION=3.14.0
ENVOY_GATEWAY_VERSION=v1.10.0
NAMESPACE=shop

# Run from the repo root, wherever the script is called from.
cd "$(dirname "$0")/.."

# The image tag comes from the chart's appVersion, so the image and the chart agree.
APP_VERSION=$(awk -F'"' '/^appVersion:/ {print $2}' charts/shop/Chart.yaml)
IMAGE="shop-api:${APP_VERSION}"

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
# (and their cache) can't break or change the result: in Step 1, a stale cache for
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
for tool in docker kind kubectl helm cilium openssl curl; do
  command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not installed"
done
docker info >/dev/null 2>&1 || die "Docker isn't running"

mem_bytes=$(docker info --format '{{.MemTotal}}')
if [ "$mem_bytes" -lt 6000000000 ]; then
  info "Warning: Docker has $((mem_bytes / 1024 / 1024)) MiB of memory; 8 GiB is recommended."
fi
info "All tools found. App image: $IMAGE"

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
# Nodes stay NotReady until a CNI is installed (the kind config disables the default one).
if helm status cilium -n kube-system >/dev/null 2>&1; then
  info "Already installed, skipping."
else
  cilium install --version "$CILIUM_VERSION" --set hubble.relay.enabled=true
fi
cilium status --wait --wait-duration 5m >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=5m

# ---------------------------------------------------------------------------
step "metrics-server (chart $METRICS_SERVER_CHART_VERSION)"
# ---------------------------------------------------------------------------
# --repo points at the chart repository directly, so no `helm repo add` is needed.
helm upgrade --install metrics-server metrics-server \
  --repo https://kubernetes-sigs.github.io/metrics-server/ \
  --version "$METRICS_SERVER_CHART_VERSION" \
  -n kube-system \
  --set 'args={--kubelet-insecure-tls}' \
  --wait --timeout 5m

# ---------------------------------------------------------------------------
step "Envoy Gateway $ENVOY_GATEWAY_VERSION and GatewayClass"
# ---------------------------------------------------------------------------
helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm \
  --version "$ENVOY_GATEWAY_VERSION" \
  -n envoy-gateway-system --create-namespace \
  --wait --timeout 5m
kubectl apply -f gitops/platform/gatewayclass.yaml

# ---------------------------------------------------------------------------
step "Build $IMAGE and load it into the kind nodes"
# ---------------------------------------------------------------------------
docker build -t "$IMAGE" app/
kind load docker-image "$IMAGE" --name "$CLUSTER_NAME"

# ---------------------------------------------------------------------------
step "Namespace '$NAMESPACE' and database password"
# ---------------------------------------------------------------------------
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
step "shop chart"
# ---------------------------------------------------------------------------
helm lint charts/shop -f charts/shop/values-local.yaml >/dev/null
helm upgrade --install shop charts/shop \
  -n "$NAMESPACE" \
  -f charts/shop/values-local.yaml \
  --wait --timeout 5m

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

    To call the API yourself:
      kubectl -n envoy-gateway-system port-forward svc/$ENVOY_SVC 8888:80
      curl -H "Host: shop.local" localhost:8888/api/products
EOF
