# Cluster

## Pinned versions

| Component        | Version  | Notes                                             |
|------------------|----------|---------------------------------------------------|
| kind             | v0.33.0  | node images below are built for this release      |
| Kubernetes       | v1.36.4  | EKS standard support until 2027-08-02             |
| Cilium           | 1.20.5   | installed with the cilium CLI                     |
| cilium CLI       | v0.20.3  |                                                   |

## Create the cluster (Phase 2, Step 1)

```bash
kind create cluster --config cluster/kind.yaml
kubectl get nodes                      # NotReady is expected: no CNI yet
cilium install --version 1.20.5
cilium status --wait
kubectl get nodes                      # all three Ready
```

## Delete

```bash
kind delete cluster --name lab
```
