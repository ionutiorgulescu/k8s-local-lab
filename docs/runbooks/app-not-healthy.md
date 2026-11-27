# App `Degraded` or stuck `Progressing`

Health describes what's running; sync describes whether it matches Git. A broken release is
**Synced + Degraded**: Argo CD applied exactly what Git says, and it doesn't work.

## 1. Which object is unhealthy?

```bash
argocd app get shop | grep -vE ' Healthy |Synced  *$'
kubectl -n shop get pods
```

## 2. Match the symptom

| Symptom | Cause | Fix |
|---|---|---|
| New pod `ErrImagePull` / `ImagePullBackOff`, old pods still Running | Image tag doesn't exist or isn't pullable (private package, typo) | `kubectl -n shop events --for pod/<pod>`; `git revert` the commit that set the tag |
| Pod `CrashLoopBackOff`, `Last State: OOMKilled`, exit 137 | Memory limit too low (no trace in app logs) | `kubectl -n shop describe pod <pod> \| grep -A6 'Last State'`; raise the limit in `gitops/envs/local/shop.yaml` |
| Pod `CrashLoopBackOff`, `Reason: Error` | The process exits at startup | `kubectl -n shop logs <pod> --previous` |
| API pods `0/1 Running`, 0 restarts | Readiness failing: `/readyz` checks Postgres | `kubectl -n shop get pods postgres-0`; API logs (`ENOTFOUND postgres` = no ready Postgres pod behind the headless Service) |
| Deployment `Progressing=False (ProgressDeadlineExceeded)` | A rollout made no progress for 10 min (`progressDeadlineSeconds`) | Find the stuck new pod above; fix forward or `git revert` |
| Only the HPA is unhealthy, for a minute after a rollout | No CPU metrics yet for new pods (`FailedGetResourceMetric`) | Wait; if it persists, check metrics-server: `kubectl top pods -n shop` |
| `root` Degraded | A child app is unhealthy (health propagates up) | `argocd app list`, then follow the child |

## 3. Remember

- With `maxUnavailable: 0`, a broken new version never replaces working pods: users keep
  being served while you fix it.
- Alert on Degraded only after it lasts a few minutes, or every rollout pages someone.
