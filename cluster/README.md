# Cluster

## Rebuild everything

```bash
./cluster/bootstrap.sh
```

Does only what Argo CD can't do for itself: creates the kind cluster, installs Cilium (with
Hubble Relay), installs Argo CD, creates the `shop`
namespace and the database password, and applies `gitops/root.yaml`. Argo CD then deploys
everything else from GitHub's `main` (see `gitops/README.md`). The script waits until every
Application is Synced and Healthy, then checks `/api/products` through the gateway.

Argo CD deploys what's **pushed**, not your working copy; the script warns about unpushed
commits. Safe to re-run.

The sections below are the manual steps from Phases 2 and 3, kept as reference. Since
Phase 3, metrics-server, Envoy Gateway, the GatewayClass and the app are installed by Argo CD,
not by hand.

## Pinned versions

Versions of Argo CD-managed components are pinned in `gitops/apps/*.yaml`; the bootstrap
pieces (Cilium, Argo CD) in `bootstrap.sh`. Keep this table in sync with both.

| Component        | Version  | Notes                                             |
|------------------|----------|---------------------------------------------------|
| kind             | v0.33.0  | node images below are built for this release      |
| Kubernetes       | v1.36.4  | EKS standard support until 2027-08-02             |
| Cilium           | 1.20.5   | cilium CLI; replaces kube-proxy (no kube-proxy in the cluster) |
| cilium CLI       | v0.20.3  |                                                   |
| hubble CLI       | v1.20.4  | `brew install hubble`                             |
| metrics-server   | chart 3.14.0 (app v0.9.0) | 0.9.x supports Kubernetes 1.34+   |
| Envoy Gateway    | v1.10.0  | Envoy 1.40, Gateway API v1.6.1, tested on Kubernetes 1.34–1.37; EOL 2027-05-05 |
| Argo CD          | v3.6.2 (chart argo-cd 10.19.0) | 3.6 tested on Kubernetes 1.34–1.37 |
| argocd CLI       | v3.6.2   | `brew install argocd`                             |

## Create the cluster (Phase 2, Step 1)

```bash
kind create cluster --config cluster/kind.yaml
kubectl get nodes                      # NotReady is expected: no CNI yet
cilium install --version 1.20.5 --set hubble.relay.enabled=true \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=lab-control-plane --set k8sServicePort=6443
cilium status --wait
kubectl get nodes                      # all three Ready
```

Since Phase 3 the cluster has **no kube-proxy** (`kubeProxyMode: none` in `kind.yaml`): Cilium
handles Services and NodePorts with eBPF. See `docs/decisions/0001-cilium-kube-proxy-replacement.md`.
Check it with:

```bash
kubectl -n kube-system get daemonset kube-proxy       # NotFound
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep KubeProxyReplacement
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
  --version 3.14.0 --set 'args={--kubelet-insecure-tls}'
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
kubectl apply -f gitops/platform/gatewayclass.yaml   # cluster-wide; the app's Gateway comes from the chart
```

kind has no cloud load balancer. With the default LoadBalancer Service, EXTERNAL-IP stays
`<pending>`, the Gateway stays `PROGRAMMED: False`, and Argo CD reports it as Progressing
forever. So `gitops/platform/gatewayclass.yaml` links the GatewayClass to an `EnvoyProxy` that
uses a **NodePort Service on port 30080**, and `cluster/kind.yaml` publishes that port on the
Mac as `127.0.0.1:8088`. No port-forward needed:

```bash
curl http://shop.localhost:8088/api/products
```

Or open http://shop.localhost:8088 in a browser. Names ending in `.localhost` always mean this
machine: curl, Chrome and Firefox resolve them with no `/etc/hosts` entry (Safari uses the
system resolver and needs `127.0.0.1  shop.localhost` in `/etc/hosts`). The lab first used
`shop.local`, but on macOS `.local` names go to Bonjour (mDNS) first: every lookup took 5 s.

(Before this, the Service was ClusterIP and reached with
`kubectl -n envoy-gateway-system port-forward svc/<envoy-service> 8888:80`.)

## Argo CD (Phase 3, Step 1)

```bash
helm upgrade --install argocd argo-cd --repo https://argoproj.github.io/argo-helm \
  --version 10.19.0 -n argocd --create-namespace -f gitops/argocd/values.yaml --wait
```

Web UI (plain HTTP inside the cluster, `server.insecure`):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80   # then http://localhost:8080
argocd admin initial-password -n argocd                    # first login as admin
```

CLI: `kubectl port-forward` tends to break on the CLI's gRPC traffic, so let the CLI make
its own tunnel for every command:

```bash
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
argocd login --username admin       # server address comes from ARGOCD_OPTS
argocd account update-password
kubectl -n argocd delete secret argocd-initial-admin-secret
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
