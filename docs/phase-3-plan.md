# Phase 3: GitOps with Argo CD

Goal: Git becomes the only way to change what runs in the cluster. Argo CD watches this
repository and keeps the cluster matching it: the app (`charts/shop`) and the platform
add-ons (metrics-server, Envoy Gateway). Nobody runs `helm upgrade` or `kubectl apply`
for routine changes anymore.

Where this plan says **pin**, look up the current release and write the exact version into
your files, as in Phase 2.

Commit after every step. From this phase on, a step usually isn't done until it's **pushed**,
because Argo CD reads GitHub, not your laptop.

---

## Step 0: Starting point

- The Phase 2 cluster, rebuilt with `./cluster/bootstrap.sh` (all checks green).
- This repository on GitHub, public (Argo CD can read it without credentials).
- Install the `argocd` CLI (**pin**: match the Argo CD version you install in Step 1).

New repo folder for everything Argo CD reads that isn't the app chart:

```
gitops/
├── argocd/        # Argo CD's own Helm values
├── apps/          # Application manifests (one per thing Argo CD deploys)
└── platform/      # plain manifests: namespace, GatewayClass
```

**Verify:** `argocd version --client` works; the `shop` app answers through the gateway.

---

## Step 1: Install Argo CD

Install with the official Helm chart (**pin** the chart version) into namespace `argocd`,
with values in `gitops/argocd/values.yaml`. Keep it small for kind:

- disable Dex (no SSO yet) and the notifications controller
- one replica of each component

Log in to the UI through a port-forward with the initial admin password, then change it.

Learn the components: API server + UI, repo-server (renders Helm/manifests from Git),
application-controller (compares and syncs), Redis (cache), ApplicationSet controller.

**Verify:** UI reachable at `localhost:8080` via port-forward; `argocd login` works.

---

## Step 2: First Application, synced by hand

`gitops/apps/shop.yaml`: an `Application` pointing at this repo, path `charts/shop`,
value file `values-local.yaml`, destination namespace `shop`. **No automated sync yet.**

The app is currently a Helm release created with `helm install`. Argo CD doesn't use Helm
releases: it renders the chart (like `helm template`) and applies the result itself. So:

1. Create the Application; look at the diff Argo CD shows against what's running.
2. Sync manually; Argo CD takes over the existing objects.
3. Remove Helm's release records **without deleting the objects** (the `sh.helm.release.v1.shop.*`
   Secrets). Otherwise someone running `helm uninstall` later would delete the live app.

**Verify:** app `Synced` and `Healthy` in the UI and `argocd app get shop`; `helm list -n shop`
is empty; `/api/products` still works.

---

## Step 3: Automated sync, prune and self-heal

Turn on `syncPolicy.automated` with `prune: true` and `selfHeal: true`.

Experiments:

- **Drift:** `kubectl -n shop edit configmap api-config` (change `LOG_LEVEL`). Watch Argo CD
  put it back.
- **Manual scale:** `kubectl -n shop scale deploy/api --replicas=5`. Who wins, Argo CD or the HPA?
  (The chart leaves `replicas` out when autoscaling is on; explain what you see.)
- **Prune:** delete a template from the chart in Git (e.g. disable the PDB via values), push,
  watch the object disappear from the cluster.

**Verify:** each manual change is reverted within the sync interval (or immediately on
self-heal); you can explain `Synced` vs `Healthy` and `OutOfSync` vs `Degraded`.

---

## Step 4: Change and roll back through Git only

- Change `api.logLevel` in `values-local.yaml`, commit, push. Watch the rollout start on its own
  (the `checksum/config` annotation from Phase 2).
- Roll back with `git revert`, not with the Argo CD UI.

Discuss: why "rollback" in Argo CD's UI is a trap with automated sync on, and why `git revert`
is the real rollback.

**Verify:** `git log` alone explains every change the cluster went through.

---

## Step 5: App of Apps and the platform

Move everything Argo CD should own into Git, managed by one root Application:

- `gitops/apps/root.yaml`: points at `gitops/apps/` and creates every Application in it.
- `gitops/apps/platform.yaml`: plain manifests from `gitops/platform/` (the `shop` namespace
  with its Pod Security labels, the GatewayClass).
- `gitops/apps/metrics-server.yaml`, `gitops/apps/envoy-gateway.yaml`: Helm charts from their
  upstream repositories (**pin** the same versions as Phase 2), with values from the repo.
- `gitops/apps/shop.yaml`: from Step 2.

Use **sync waves** for ordering: namespace and CRD-providing charts first, then the
GatewayClass, then the app.

Not managed by Argo CD (bootstrap only): the kind cluster, Cilium (the network must exist
before anything else can run), Argo CD itself, and the database password Secret (Phase 6).

**Verify:** the root app shows every child `Synced` and `Healthy`; `helm list -A` shows no
releases except Cilium.

---

## Step 6: Projects and access

- An `AppProject` for the shop: may deploy only from this repository, only into namespace
  `shop`, only namespaced resource kinds.
- A separate project for the platform apps, allowed cluster-scoped resources.
- Read-only Argo CD role for developers (Argo CD RBAC, `policy.csv`), mirroring the Phase 2
  Kubernetes RBAC.

**Verify:** an Application in the shop project that targets `kube-system` is rejected.

---

## Step 7: Break it on purpose

Write what you observed in `docs/phase-3-drills.md`:

1. **Bad commit:** push an image tag that doesn't exist. Argo CD shows `Degraded` / `Progressing`;
   the old pods keep serving (Phase 2's `maxUnavailable: 0`). Recover with `git revert`.
2. **Invalid manifest:** push a chart change that doesn't render (e.g. remove a required value).
   Find the error in Argo CD, not in the cluster.
3. **Manual hotfix:** change something with `kubectl` during an "incident". Watch self-heal undo it.
   How do teams handle real emergencies with GitOps?
4. **Argo CD down:** scale the Argo CD controller to 0. The app keeps running; drift is no longer
   corrected. Scale back and watch it catch up.
5. **Deleted Application:** delete the `shop` Application with and without cascading. What happens
   to the running app each way? (Finalizers.)

---

## Step 8: Bootstrap, GitOps style

Rewrite `cluster/bootstrap.sh` to do only what Argo CD can't do for itself:

1. kind cluster
2. Cilium
3. the `shop-api` image (`kind load`; CI and a registry come later)
4. Argo CD (Helm, pinned) and the root Application
5. the database password Secret
6. wait until every Application is `Synced` and `Healthy`, then the same smoke test as Phase 2

**Verify:** `kind delete cluster --name lab && ./cluster/bootstrap.sh` ends green, and the
platform and app came from Git through Argo CD.

---

## Not in this phase

- Building and publishing the image in CI, and updating the tag in Git automatically (CI phase).
- Secrets from a secret manager (Phase 6: External Secrets).
- SSO for Argo CD, multiple clusters, ApplicationSets for many environments (EKS phase).
