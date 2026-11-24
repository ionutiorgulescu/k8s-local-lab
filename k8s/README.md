# Kubernetes manifests

The app itself (API, Postgres, Gateway route, autoscaling, NetworkPolicies, RBAC) is
deployed with the Helm chart in [`charts/shop`](../charts/shop). The hand-written manifests
it replaced (`10-postgres.yaml` to `60-rbac.yaml`) are in Git history (Phase 2, Steps 5–10).

What stays here is what the chart expects to exist already.

## 1. Namespace with Pod Security

```bash
kubectl apply -f k8s/00-namespace.yaml
```

The `shop` namespace enforces the `restricted` Pod Security Standard (pinned to v1.36).
Every pod needs `runAsNonRoot: true`, `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]` and `seccompProfile.type: RuntimeDefault`.

A Deployment or StatefulSet that violates it is still created, but its pods are rejected.
Find out why with:

```bash
kubectl -n shop get events --field-selector reason=FailedCreate
```

## 2. Database password

Created by command so it never lands in Git (Phase 6 replaces this with External Secrets):

```bash
kubectl -n shop create secret generic postgres-credentials \
  --from-literal=password="$(openssl rand -base64 24)"
```

## 3. The app

```bash
helm lint charts/shop -f charts/shop/values-local.yaml
helm upgrade --install shop charts/shop -n shop -f charts/shop/values-local.yaml
```

`helm upgrade --install` installs the first time and upgrades afterwards. Inspect changes
before applying them:

```bash
helm template shop charts/shop -n shop -f charts/shop/values-local.yaml | kubectl diff -n shop -f -
```
