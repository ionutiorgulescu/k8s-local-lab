# Kubernetes manifests

Apply in filename order. The numeric prefixes set that order (namespace first).

## Before the manifests: the database password

Created by command so it never lands in Git (Phase 6 replaces this with External Secrets):

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl -n shop create secret generic postgres-credentials \
  --from-literal=password="$(openssl rand -base64 24)"
```

## Pod Security

The `shop` namespace enforces the `restricted` Pod Security Standard (pinned to v1.36).
Every pod needs `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]` and `seccompProfile.type: RuntimeDefault`.

A Deployment or StatefulSet that violates it is still created, but its pods are rejected.
Find out why with:

```bash
kubectl -n shop get events --field-selector reason=FailedCreate
```
