# Cluster

## Pinned versions

| Component        | Version  | Notes                                             |
|------------------|----------|---------------------------------------------------|
| kind             | v0.33.0  | node images below are built for this release      |
| Kubernetes       | v1.36.4  | EKS standard support until 2027-08-02             |
| Cilium           | 1.20.5   | installed with the cilium CLI                     |
| cilium CLI       | v0.20.3  |                                                   |
| metrics-server   | chart 3.14.0 (app v0.9.0) | 0.9.x supports Kubernetes 1.34+   |

## Create the cluster (Phase 2, Step 1)

```bash
kind create cluster --config cluster/kind.yaml
kubectl get nodes                      # NotReady is expected: no CNI yet
cilium install --version 1.20.5
cilium status --wait
kubectl get nodes                      # all three Ready
```

## metrics-server (Phase 2, Step 2)

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server -n kube-system \
  --version 3.14.0 -f cluster/metrics-server-values.yaml
kubectl -n kube-system rollout status deploy/metrics-server
kubectl top nodes                      # numbers after about a minute
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
