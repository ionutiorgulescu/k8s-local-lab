# Phase 3, Step 7: GitOps failure drills

Each drill: what was done, what was observed, and what it shows.

---

## 1. Bad commit (image tag that doesn't exist)

**Done:** committed `api.image.tag: "0.9.9"` in `charts/shop/values-local.yaml` (no such image)
and pushed, with traffic going through Envoy. Recovered with `git revert` of that commit.

**Observed:**

- Argo CD synced the commit: `shop` **Synced**, health **Progressing**. One new API pod in
  `ImagePullBackOff`; the old pods kept running (`maxUnavailable: 0`).
- About 10 minutes after the sync (`progressDeadlineSeconds: 600`), the Deployment's condition
  became `Progressing=False (ProgressDeadlineExceeded)` and Argo CD showed `shop` **Degraded**,
  still **Synced**.
- `root` showed the same health (Progressing, then Degraded): the Application health check from
  Step 5 propagates a child's health to its parent.
- After pushing the revert, the broken pod was removed (the Deployment returned to its previous
  ReplicaSet; the old pods were never replaced) and `shop` and `root` went back to Healthy.
- Traffic through the gateway: only `200` for the whole drill (~15 minutes of a broken release).

**What it shows:**

- **Synced and Healthy answer different questions.** Synced = "the cluster matches Git".
  Healthy = "what's running works". A broken release is Synced + Degraded.
- Degraded appears only when Kubernetes declares the rollout failed (the progress deadline),
  not as soon as a pod can't start. Lower `progressDeadlineSeconds` to find out sooner.
- The rollback is a `git revert`, same as Step 4. The bad commit and its revert both stay in
  history.

### Found along the way: a rejected Application fails quietly

While drill 1 ran, the UI showed `platform` with sync and health **Unknown**:

```
InvalidSpecError  application destination server 'https://kubernetes.default.svc' and
namespace '' do not match any of the allowed destinations in project 'platform'
```

Since Step 6, the `platform` Application had no destination namespace, and the `platform`
project only allows listed namespaces, so Argo CD rejected the Application's spec. It had been
like this since the Step 6 push, unnoticed, because nothing broke: the shop namespace and the
GatewayClass kept running. But nobody was managing them (no self-heal, no updates from Git).
Fixed by giving the Application `namespace: envoy-gateway-system`.

- A rejected Application doesn't fail loudly; it just stops managing its objects.
- After changing projects or Application specs, check **every** Application, not only the one
  being tested.
- In production, alert on Applications in `Unknown` or `Degraded` (Argo CD exports metrics for
  this; Prometheus comes in Phase 4).

---

## 2. A chart that doesn't render

**Done:** committed `postgres.enabled: false` in `values-local.yaml` without setting
`database.host` (the "moving to a managed database but forgot the host" mistake) and pushed.
Recovered with `git revert`.

**Observed:**

- `shop`: Sync Status **Unknown**, Health **Healthy**, with a condition:
  ```
  ComparisonError  Failed to load target state: failed to generate manifest ...
  failed to execute helm template command: `helm template . --name-template shop --namespace shop
  --kube-version 1.36.4 --values .../charts/shop/values-local.yaml --include-crds` failed exit status 1:
  Error: execution error at (shop/templates/api-deployment.yaml:31:28):
  database.host is required when postgres.enabled is false
  ```
- Nothing was applied: `postgres-0` kept its age (2d20h), the API kept serving.
- After the revert, the condition cleared and the app was Synced again.

**What it shows:**

- When Git can't be rendered, Argo CD reports a **ComparisonError** (sync Unknown) and changes
  nothing. The error, including the chart's own message, is visible in Argo CD, so a developer
  without cluster access can see why.
- The error shows the exact `helm template` command the repo-server runs (release name,
  namespace, `--kube-version`, `--include-crds`). Running the same command locally reproduces
  any rendering error.
- The chart's `fail` guard (Phase 2, Step 12) mattered: without it the chart would have rendered
  *without* Postgres, and with `prune: true` Argo CD would have deleted the database StatefulSet.
  Validate dangerous value combinations in the chart, so mistakes fail before they're applied.
