# Rebuild the lab from scratch

```bash
git pull && git status          # Argo CD deploys GitHub's main: push local commits first
kind delete cluster --name lab
./cluster/bootstrap.sh          # ~10 min; ends with a smoke test through localhost:8088
```

The script stops at the first failure and names the stage. It refuses to continue on a cluster
that still runs kube-proxy (recreate it). If the "waiting for Applications" stage times out,
it prints the Application table: follow [argocd-sync-problems.md](argocd-sync-problems.md) or
[app-not-healthy.md](app-not-healthy.md).

## After a rebuild

- **Argo CD admin password** is new and random:
  ```bash
  argocd admin initial-password -n argocd
  export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
  argocd login --username admin && argocd account update-password
  kubectl -n argocd delete secret argocd-initial-admin-secret
  ```
- **The `dev` account** has no password: `argocd account update-password --account dev`.
- **The database is new** (new volume, new password Secret): the API seeds its sample products.
- **Hubble CLI**: `hubble status -P`.

## Common failures

| Stage | Symptom | Fix |
|---|---|---|
| Checking prerequisites | "Docker isn't running" / memory warning | Start Docker Desktop; give it 8 GB |
| Cilium | Helm "no cached repo found" | Fixed in the script (private Helm config); don't run `cilium install` by hand with stale global repos |
| any | metrics-server `CrashLoopBackOff`, "certificate and key must be supplied as a pair" | Docker's disk is full: `docker system df`, `docker builder prune -a`, `docker image prune -a`, then delete the pod |
| Smoke test | `000` | [site-unreachable.md](site-unreachable.md) |
