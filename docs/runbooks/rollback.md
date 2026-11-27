# Roll back a bad change

Everything that runs comes from Git, so a rollback is a Git change too.

## Code change (API or frontend)

A code push produces two commits on `main`: yours, then CI's `Deploy shop-<service> sha-…`.
Revert **yours**; CI then builds the reverted code and deploys it (a few minutes).

```bash
git pull
git log --oneline -6
git revert <your-commit>
git push
```

Faster, when the previous image is known to be good: revert CI's `Deploy shop-<service>`
commit instead. Argo CD goes back to the previous image tag without a build. (Your code
change is still on `main`, so revert it too before the next build.)

## Settings, chart or platform change

```bash
git revert <commit>
git push
argocd app get shop --refresh
```

## Don't

- `argocd app rollback`: refused while auto-sync is on, and if you disable auto-sync to use
  it, the cluster silently stops matching Git.
- `kubectl rollout undo`: Argo CD's self-heal puts Git's version back.

## Check

```bash
argocd app history shop        # the bad revision, then the revert
curl -s http://shop.localhost:8088/api/version
```
