# `http://shop.localhost:8088` fails

The path: Mac `127.0.0.1:8088` → kind port mapping → NodePort 30080 (any node) → Envoy →
API or frontend. Find the first link that fails.

```bash
curl -s -o /dev/null -w 'http=%{http_code} lookup=%{time_namelookup}s total=%{time_total}s\n' http://shop.localhost:8088/api/products
```

| Result | Where to look |
|---|---|
| **Slow** (`lookup` ≈ 5 s) | The hostname ends in `.local` (Bonjour/mDNS on macOS). Use `shop.localhost` |
| **`000`**, connection refused | Nothing listens on 8088: `docker port lab-control-plane` must show `30080/tcp -> 127.0.0.1:8088` (only set when the cluster is created) |
| **`000`**, connected but no response | NodePort traffic dropped. Below |
| **`404`** with an empty body from Envoy | No route matches: hostname or path. `kubectl -n shop get httproute api -o yaml` (hostnames, `Accepted`, `ResolvedRefs`) |
| **`503 no healthy upstream`** | Envoy has no ready backend: see [app-not-healthy.md](app-not-healthy.md). Note Envoy's panic mode: with < 50% healthy hosts it routes to all of them anyway, so you may get the app's own `500` instead |
| **`500`** | The app answered with an error: `kubectl -n shop logs deploy/api` |

## Connected but no response

```bash
kubectl -n envoy-gateway-system get svc -l gateway.envoyproxy.io/owning-gateway-name=web \
  -o jsonpath='{.items[0].spec.type} {.items[0].spec.externalTrafficPolicy} {.items[0].spec.ports[0].nodePort}{"\n"}'
# expect: NodePort Cluster 30080

CP=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=lab-control-plane -o name)
kubectl -n kube-system exec $CP -c cilium-agent -- cilium-dbg service list | grep -E '^ID|30080'
# the external entry (without /i) must have a backend
```

An external entry with **no backends** = `externalTrafficPolicy: Local` on a node without an
Envoy pod (the port mapping always lands on the control-plane). It must be `Cluster`
(`gitops/platform/gatewayclass.yaml`).

Test each hop from inside the cluster (kind nodes are containers):

```bash
docker exec lab-control-plane curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: shop.localhost' http://localhost:30080/api/products
docker exec lab-worker curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: shop.localhost' http://lab-control-plane:30080/api/products
```

Lesson from this lab: when traffic works on some nodes and not others, check the Service's
traffic policy and per-node backends before suspecting the network datapath.
