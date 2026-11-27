# Argo CD sync problems

```bash
argocd app list
argocd app get <app> --refresh | head -25     # look for CONDITION lines
argocd app diff <app>
```

| You see | Cause | Fix |
|---|---|---|
| Sync and health **Unknown**, condition `InvalidSpecError ... do not match any of the allowed destinations in project` | The Application breaks its AppProject's rules (e.g. empty destination namespace) | Fix the Application in `gitops/apps/`, or the project in `projects.yaml`. Nothing is managed until then, and nothing breaks loudly: check **every** app after project changes |
| Sync **Unknown**, `ComparisonError ... failed to execute helm template` | The chart doesn't render (e.g. the chart's own `fail` guard) | Reproduce locally with the same command: `helm template shop charts/shop -n shop -f gitops/envs/local/shop.yaml`; fix or `git revert` |
| `OutOfSync` right after a push, then `Synced` | Normal: Argo CD fetched the commit, the automated sync follows seconds later | `argocd app get <app> --refresh` to fetch immediately instead of waiting ~3 min |
| `Synced`, but the cluster isn't what Git says | Someone **added** something next to Git's fields (e.g. `kubectl set env`): self-heal only restores fields that are in Git | Remove it by hand (`kubectl -n shop set env deploy/api VAR-`); prevent it with RBAC (nobody writes to `shop` by hand) |
| Manual `argocd app set ... --self-heal=false` reverted within seconds | The `root` app self-heals Application specs | Change the setting in `gitops/apps/*.yaml` and push |
| `argocd app rollback`: "cannot be initiated when auto-sync is enabled" | By design | Roll back with `git revert` ([rollback.md](rollback.md)) |
| `PermissionDenied ... applications, sync, shop/shop, sub: dev` | Argo CD RBAC: the `dev` account is read-only, and rules match on `<project>/<app>` | Expected for `dev`; check the app's project if a rule "doesn't work" |

Argo CD down (controller scaled to 0, crash): apps keep running, but nothing syncs or
self-heals. It catches up when it's back.
