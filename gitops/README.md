# GitOps (Argo CD)

Everything in the cluster except the bootstrap pieces is deployed by Argo CD from this
repository's `main` branch. To change what runs: edit, commit, push.

```
gitops/
├── root.yaml          root Application ("App of Apps"); the only one applied by hand
├── argocd/values.yaml Argo CD's own Helm values (installed with Helm by bootstrap)
├── apps/              one Application per component; root deploys all of them
│   ├── projects.yaml         wave -1 AppProjects "platform" and "shop" (what may go where)
│   ├── metrics-server.yaml   wave 0  Helm chart from upstream, pinned
│   ├── envoy-gateway.yaml    wave 0  Helm chart (OCI), pinned; server-side apply
│   ├── platform.yaml         wave 1  manifests in platform/
│   └── shop.yaml             wave 2  charts/shop with values-local.yaml
└── platform/
    ├── namespace-shop.yaml   shop namespace, restricted Pod Security; never deleted by Argo CD
    └── gatewayclass.yaml     GatewayClass "eg" + EnvoyProxy (ClusterIP Service on kind)
```

**Sync waves:** the root app creates lower waves first and waits for them to be Healthy
(needs the Application health check in `argocd/values.yaml`).

## Not managed by Argo CD

Created by `cluster/bootstrap.sh`, because Argo CD can't create them for itself or they
don't belong in Git:

- the kind cluster and Cilium (no pod networking without it)
- Argo CD itself, and `root.yaml`
- the database password (until External Secrets in Phase 6):

```bash
kubectl -n shop create secret generic postgres-credentials \
  --from-literal=password="$(openssl rand -base64 24)"
```

## The shop-api image

Built by CI, not by bootstrap: on every push to `main` that changes `app/`,
`.github/workflows/shop-api.yml` builds the image (amd64 + arm64), publishes
`ghcr.io/ionutiorgulescu/shop-api:sha-<commit>`, and commits that tag into
`charts/shop/values-local.yaml`. Argo CD deploys it like any other change.
`GET /api/version` shows the commit that's running.

CI adds commits to `main`, so `git pull` before you push.

## Pod Security

The `shop` namespace enforces the `restricted` Pod Security Standard (pinned to v1.36).
A Deployment or StatefulSet that violates it is created, but its pods are rejected:

```bash
kubectl -n shop get events --field-selector reason=FailedCreate
```
