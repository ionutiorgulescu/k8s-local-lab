# Phase 2, Step 11: failure drills

Each drill: what was done, what was observed, and what it shows.

---

## 1. Bad image tag

**Done:** `kubectl -n shop set image deploy/api api=shop-api:0.9.9` (a tag that doesn't
exist), with traffic going through Envoy every 0.5s. Then `kubectl -n shop rollout undo deploy/api`.

**Observed:**

- One new pod was created (`maxSurge: 1`). It went `ErrImagePull` → `ImagePullBackOff`;
  the old pods kept running. The old ReplicaSet kept all its pods; the new one had 1 pod, not ready.
- Events on the new pod:
  - `Pulling image "shop-api:0.9.9"` (x5 in ~3 min)
  - `Failed to pull image ... "docker.io/library/shop-api:0.9.9" ... pull access denied,
    repository does not exist or may require authorization`
  - `Back-off pulling image "shop-api:0.9.9"` (x9)
- `rollout status --timeout=30s` timed out waiting for the new replicas.
- Traffic through the gateway: only `200` for the whole drill (bad rollout and rollback).
- `rollout undo` printed a warning: the Deployment was managed with `kubectl apply`, and
  undo doesn't update the `last-applied-configuration` annotation.
- `rollout history` afterwards showed revisions 2 and 3: the undo reused revision 1's
  ReplicaSet and renumbered it 3.

**What it shows:**

- `maxUnavailable: 0` makes a broken rollout harmless: no old pod is removed until a new
  pod is Ready, so a new version that never becomes ready never replaces anything.
- A short image name means Docker Hub (`docker.io/library/...`). With
  `imagePullPolicy: IfNotPresent`, a tag that wasn't `kind load`ed is pulled from there.
- Docker Hub answers "doesn't exist" and "private, not logged in" with the same error.
  Check both: a typo in the name or tag, and pull credentials (`imagePullSecrets`, or IAM
  permissions for ECR on EKS).
- `ErrImagePull` is a failed attempt; `ImagePullBackOff` is the wait before the next one,
  doubling up to 5 minutes.
- Without intervention, the Deployment would be marked `ProgressDeadlineExceeded` after
  `progressDeadlineSeconds` (600s by default), which CI and Argo CD can detect.
- `rollout undo` is an emergency brake. The durable fix is reverting the change in Git and
  applying it, so the cluster, Git and kubectl's last-applied record all agree.
