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
- Traffic through the gateway: TRAFFIC_RESULT

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
