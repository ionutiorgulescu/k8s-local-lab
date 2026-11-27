# Traffic between components is blocked

Symptoms: timeouts (not "connection refused") between pods, e.g. the API can't reach
Postgres, or a pod outside `shop` can't reach the API (expected: default deny).

## See what Cilium dropped, and why

```bash
hubble observe -P --namespace shop --verdict DROPPED -f
```

```
api-…:38188 <> shop/postgres-0:5432 policy-verdict:none INGRESS DENIED (TCP Flags: SYN)
api-…:38188 <> shop/postgres-0:5432 Policy denied DROPPED (TCP Flags: SYN)
```

- `policy-verdict:none INGRESS DENIED`: no ingress rule on the **destination** allows this source.
- Source and destination show pods and their security identities (from labels, not IPs).
- Lines with `TCP Flags: ACK, PSH` mean an already open connection was cut: removing an allow
  rule breaks existing connections immediately, not only new ones.

## The allowed paths

| From | To | Policy |
|---|---|---|
| `envoy-gateway-system` namespace | API pods :8080 | `api-from-gateway` |
| `envoy-gateway-system` namespace | frontend pods :8080 | `frontend-from-gateway` |
| API pods | Postgres :5432 | `postgres-from-api` |
| anything else | anything in `shop` | denied (`default-deny-ingress`) |

Policies come from `charts/shop/templates/networkpolicies.yaml`; a missing one is restored by
Argo CD's self-heal within seconds.

Ignore `ICMPv6 RouterSolicitation ... Unsupported L3 protocol DROPPED`: pods asking for an IPv6
router on an IPv4 cluster.
