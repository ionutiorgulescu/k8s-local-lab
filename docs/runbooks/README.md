# Runbooks

Start from what you see; each runbook leads to the cause and the fix. Built from the failure
drills in `docs/lab/` and real incidents in this lab.

| You see | Runbook |
|---|---|
| Argo CD app `Degraded` or stuck `Progressing` | [app-not-healthy.md](app-not-healthy.md) |
| Argo CD app `Unknown`, `OutOfSync` that won't sync, or "Synced" while the cluster differs | [argocd-sync-problems.md](argocd-sync-problems.md) |
| `http://shop.localhost:8088` fails (`000`, `404`, `500`, `503`, or slow) | [site-unreachable.md](site-unreachable.md) |
| One component can't reach another (timeouts between pods) | [network-policy-drops.md](network-policy-drops.md) |
| A bad change went out | [rollback.md](rollback.md) |
| Rebuilding the lab from scratch | [rebuild-cluster.md](rebuild-cluster.md) |

Set up the CLI once per terminal:

```bash
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --plaintext'
```
