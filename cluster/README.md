# Cluster

## Rebuild everything

```bash
./cluster/bootstrap.sh
```

Creates the kind cluster, installs Cilium (with Hubble Relay), metrics-server and Envoy
Gateway, builds and loads the `shop-api` image, creates the namespace and the database
password, installs the `shop` chart, and checks `/api/products` through the gateway.
Safe to re-run. The sections below explain each step by hand.

## Pinned versions

When you change a version here, change it in `bootstrap.sh` too.

| Component        | Version  | Notes                                             |
|------------------|----------|---------------------------------------------------|
| kind             | v0.33.0  | node images below are built for this release      |
| Kubernetes       | v1.36.4  | EKS standard support until 2027-08-02             |
| Cilium           | 1.20.5   | installed with the cilium CLI                     |
| cilium CLI       | v0.20.3  |                                                   |
| hubble CLI       | v1.20.4  | `brew install hubble`                             |
| metrics-server   | chart 3.14.0 (app v0.9.0) | 0.9.x supports Kubernetes 1.34+   |
| Envoy Gateway    | v1.10.0  | Envoy 1.40, Gateway API v1.6.1, tested on Kubernetes 1.34–1.37; EOL 2027-05-05 |

## Create the cluster (Phase 2, Step 1)

```bash
kind create cluster --config cluster/kind.yaml
kubectl get nodes                      # NotReady is expected: no CNI yet
cilium install --version 1.20.5
cilium status --wait
kubectl get nodes                      # all three Ready
```

## Hubble (Phase 2, Step 11)

Hubble records every forward/drop decision Cilium makes. Relay combines all nodes' flows.

```bash
cilium hubble enable                 # helm upgrade of the cilium release; keeps chart 1.20.5
cilium status --wait                 # Hubble Relay: OK
hubble status -P                     # -P: the CLI port-forwards to Relay itself
hubble observe -P --namespace shop --verdict DROPPED -f
```

For a fresh cluster, enable it at install time instead:
`cilium install --version 1.20.5 --set hubble.relay.enabled=true`

## metrics-server (Phase 2, Step 2)

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --version 3.14.0 -f cluster/metrics-server-values.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes                      # numbers after about a minute
```

## Envoy Gateway (Phase 2, Step 7)

Installs the Gateway API CRDs and the controller. The chart is stored in an OCI registry,
so there is no `helm repo add`.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system wait --for=condition=Available deploy/envoy-gateway --timeout=5m
kubectl apply -f cluster/gatewayclass.yaml   # cluster-wide; the app's Gateway comes from the chart
```

kind has no cloud load balancer: the Envoy Service's EXTERNAL-IP stays `<pending>` and the
Gateway shows `PROGRAMMED: False` (no address). Traffic still works through port-forward:

```bash
kubectl -n envoy-gateway-system port-forward svc/$(kubectl -n envoy-gateway-system get svc \
  -l gateway.envoyproxy.io/owning-gateway-name=web -o jsonpath='{.items[0].metadata.name}') 8888:80
curl -H "Host: shop.local" localhost:8888/api/products
```

## Troubleshooting

**metrics-server in CrashLoopBackOff with
`error reading /tmp/apiserver.key, certificate and key must be supplied as a pair`:**
Docker Desktop's disk is full. The first start created an empty `apiserver.crt` but
couldn't write the key, and the `emptyDir` keeps that file across container restarts.
Check with `docker exec lab-worker df -h /var`, free space (`docker system df`,
`docker builder prune -a`, `docker image prune -a`), then delete the pod so it gets a
fresh `emptyDir`.

## Delete

```bash
kind delete cluster --name lab
```
