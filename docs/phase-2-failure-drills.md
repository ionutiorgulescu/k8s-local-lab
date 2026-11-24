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

---

## 2. Database outage

**Done:** `kubectl -n shop scale statefulset postgres --replicas=0` with traffic going through
Envoy every 0.5s; later `--replicas=1`.

**Observed:**

- Both API pods went `1/1` → `0/1`, stayed `Running`, with **0 restarts** for the whole outage
  (liveness `/healthz` kept passing; readiness `/readyz` failed).
- Endpoints for Service `api`: both `ready=false`.
- PDB `api`: `ALLOWED DISRUPTIONS 0` (no pod ready, so `minAvailable: 1` was already unmet;
  a `kubectl drain` would have been blocked).
- API logs: `ENOTFOUND` from `getaddrinfo` for hostname `postgres`, not "connection refused".
- Traffic: `200` → `{"statusCode":500,"message":"Internal server error"} [500]`, and it **stayed
  500** even after both pods were not ready. Expected a `503 no healthy upstream` from Envoy;
  it never came.
- Envoy admin (`port-forward` to port 19000 on the Envoy pod):
  - `/clusters`: both hosts `health_flags::/eds_status_draining`
  - `/stats`: `lb_healthy_panic: 702`, `membership_healthy: 0`, `membership_total: 2`
- After `--replicas=1`: API pods back to `1/1` within seconds, by themselves; traffic back to `200`.

**What it shows:**

- Liveness vs readiness works as designed: a database outage takes API pods out of service
  without restarting them, and they recover automatically when it returns.
- **Headless Service + no ready pods = the DNS name doesn't exist.** `postgres` (clusterIP: None)
  resolves to pod IPs, so with no ready pod DNS returns nothing (`ENOTFOUND`). A normal Service
  would still resolve to its virtual IP and fail at connect instead. During debugging, a DNS
  error for a headless Service can simply mean "no pod is ready".
- **Envoy's panic mode.** Kubernetes and Envoy Gateway both did their part: the not-ready pods
  reached Envoy flagged as draining. But when fewer than 50% of hosts are healthy (here 0 of 2),
  Envoy ignores health flags and spreads traffic across all hosts, on the theory that a mass
  "unhealthy" signal is more likely wrong than true. So requests kept reaching the app (500)
  instead of being rejected by Envoy (503).
  - Harmless in a total outage (an error either way), but in a partial failure (e.g. 3 of 4 pods
    unready) it sends traffic to pods that are starting up or shutting down.
  - General lesson: every proxy or load balancer in front of Kubernetes has its own policy for
    unhealthy backends (Envoy panic mode, AWS target groups failing open...). Readiness in the
    EndpointSlice is an input to that policy, not a guarantee.
- The PDB can block node maintenance during an outage, because it counts only ready pods.

---

## 3. Out of memory

**Done:** `kubectl -n shop set resources deploy/api -c api --requests=memory=32Mi --limits=memory=32Mi`
(the request had to drop too: a limit below the request is rejected), with traffic going
through Envoy every 0.5s. Recovered with `kubectl apply -f k8s/20-api.yaml`.

**Observed:**

- The resource change started a rolling update. The new pod was started 3 times in 29s, then
  went into `CrashLoopBackOff`; the old pods kept serving. Traffic: only `200` throughout.
- Pod events: `Startup probe failed: ... connect: connection refused`, `Started (x3)`,
  `Back-off restarting failed container`. **Nothing about memory.**
- `describe` → container status:
  ```
  Last State:     Terminated
    Reason:       OOMKilled
    Exit Code:    137
    Started:      14:18:46
    Finished:     14:18:46
  Restart Count:  3
  ```
  Killed in the same second it started: Node.js exceeded 32Mi while still loading, before
  listening on 8080 (hence the startup probe's "connection refused").
- `kubectl get pods -w` timeline for the new pod: `Running` → `OOMKilled` → `CrashLoopBackOff`,
  restarting at ~1s, 12s, 38s and 83s after creation. The gaps grow because the kubelet waits
  10s, 20s, 40s... (capped at 5 min) between restarts; `CrashLoopBackOff` is that waiting time.
  The old pods stayed `1/1 Running` the whole time. At 89s the pod went `Terminating`: the
  `kubectl apply` below restored the old template and the Deployment removed it.
- `kubectl apply -f k8s/20-api.yaml` restored `requests.memory: 128Mi`, `limits.memory: 256Mi`.

**What it shows:**

- The memory limit is enforced by the kernel: going over it means an immediate SIGKILL. The
  app can't log anything, so **an OOM kill never shows up in application logs**.
- **Where to find it:** the container's `Last State` (`Reason: OOMKilled`), not the pod's events
  (they only say "restarting failed container"). For a whole namespace:
  ```bash
  kubectl get pods -o custom-columns='NAME:.metadata.name,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason'
  ```
- **Exit code 137 has two meanings.** Both are SIGKILL (128 + 9):
  `Reason: OOMKilled` = the kernel, for exceeding the memory limit;
  `Reason: Error` = e.g. the kubelet after `terminationGracePeriodSeconds` ran out.
  The exit code alone can't tell them apart; the Reason can.
- `maxUnavailable: 0` protected users again: a new version that crashes never replaces a
  working pod.
- `kubectl apply` resets every field the file sets, including ones changed imperatively with
  `set resources` (the same reason it resets `replicas`). Recovering by applying the manifest
  from Git restores the intended state exactly.
- Sizing: base limits on measured usage (`kubectl top pods`, and later Prometheus over time,
  including peak load), with headroom. For Node.js specifically, setting `--max-old-space-size`
  below the container limit makes the JS heap fail first with a logged error, instead of a
  silent kernel kill.
