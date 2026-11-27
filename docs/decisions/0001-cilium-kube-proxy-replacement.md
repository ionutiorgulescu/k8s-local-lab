# 0001: Cilium replaces kube-proxy

- **Status:** accepted, but its motivation was wrong (see the correction below); the choice
  stands for now, to be revisited in the EKS phase
- **Date:** 2026-11-27

## Correction (2026-11-27, same day)

The diagnosis in "Context" below was wrong. After switching to kube-proxy replacement, the
Mac still got no response. Cilium's service list on the control-plane showed why:

```
ID   Frontend               Service Type   Backend
19   0.0.0.0:30080/TCP      NodePort                                  <- external traffic: no backends
21   0.0.0.0:30080/TCP/i    NodePort       1 => 10.244.1.78:10080     <- internal traffic: Envoy
```

Envoy Gateway creates the Envoy Service with **`externalTrafficPolicy: Local`**: traffic from
outside the cluster may only use an Envoy pod on the node it arrived at. The kind port mapping
lands on the control-plane, which never runs Envoy, so requests from the Mac were dropped,
with kube-proxy and with Cilium alike. The earlier test results fit this too: requests sent
straight to the node running Envoy worked, and kube-proxy treats `localhost` NodePort traffic
specially. The "kube-proxy to VXLAN hand-off" explanation was a guess that wasn't checked
against the Service's traffic policy.

Fix: `externalTrafficPolicy: Cluster` in the EnvoyProxy (`gitops/platform/gatewayclass.yaml`).

What that means for this decision: kube-proxy replacement didn't fix the problem and wasn't
needed for it. It's kept because it works, it's Cilium's documented setup for kind, and it
matches EKS clusters that run Cilium; but it's now a preference, not a requirement. Default
EKS keeps kube-proxy, so reconsider this when the EKS phase chooses its networking.

Lesson: when traffic to a Service is dropped on some nodes and not others, check the
Service's `externalTrafficPolicy` (and the backends per node, e.g. `cilium-dbg service list`)
before suspecting the datapath.

---

*Original record below, unchanged.*

## Context

To reach the gateway without `kubectl port-forward`, Envoy's Service became a NodePort
(30080) and kind publishes it on the Mac (`cluster/kind.yaml`: `127.0.0.1:8088 -> 30080` on
the control-plane node). The bootstrap smoke test then failed with `000`: the connection was
accepted, but no response ever came.

Investigation (kube-proxy in iptables mode + Cilium 1.20.5, VXLAN tunnel, no kube-proxy
replacement):

| Request | Envoy pod on the receiving node? | Result |
|---|---|---|
| `lab-worker:30080`, from lab-worker and from lab-worker2 | yes | 200 |
| `lab-control-plane:30080` via the node IP, from itself, from lab-worker, from the Mac | no | no response |
| `localhost:30080` inside lab-control-plane | no | 200 (kube-proxy always SNATs localhost NodePort traffic) |

Hubble showed the working requests reaching the Envoy pod through the overlay; the failing
ones never reached it and produced no drop events. So NodePort traffic that kube-proxy had to
forward to a pod on another node was lost on the receiving node, in the hand-off between
kube-proxy (iptables DNAT) and Cilium's VXLAN datapath. The exact rule wasn't identified.

## Options

1. **Cilium kube-proxy replacement (KPR):** no kube-proxy (`kubeProxyMode: none`), Cilium
   handles Services, NodePorts and the hand-off itself in eBPF. Cilium's documented setup for
   kind.
2. **Keep kube-proxy, avoid cross-node forwarding:** Envoy as a DaemonSet on every node
   (including the control-plane) with `externalTrafficPolicy: Local`. Works around the
   symptom; the broken path stays for any other NodePort.
3. **Keep port-forward:** no NodePort at all.

## Decision

Option 1. `cluster/kind.yaml` sets `kubeProxyMode: "none"`; `cluster/bootstrap.sh` installs
Cilium with `kubeProxyReplacement=true`, `k8sServiceHost=lab-control-plane`,
`k8sServicePort=6443` (without kube-proxy, Cilium can't use the `kubernetes` Service IP to
reach the API server, since it's the component that would translate it).

## Consequences

- One component for pod networking, NetworkPolicies and Services; the failing hand-off is gone.
- Not the default EKS setup. Default EKS uses the VPC CNI (no overlay) plus kube-proxy, and
  load balancers in IP-target mode send traffic straight to pod IPs, so this problem doesn't
  arise there. KPR matches EKS clusters that run Cilium instead of the VPC CNI. The EKS phase
  decides between the two.
- Changing kube-proxy mode means recreating the cluster. `bootstrap.sh` refuses to continue
  on a cluster that still runs kube-proxy.
- Debugging Services moves from iptables rules to Cilium: `cilium-dbg service list`,
  `cilium-dbg status`, Hubble.

## How it's verified

1. `kubectl -n kube-system get daemonset kube-proxy` returns NotFound.
2. `cilium-dbg status` in a Cilium pod reports `KubeProxyReplacement: True`.
3. The cross-node case: `lab-control-plane:30080` (no Envoy on that node) answers 200, and
   `curl http://shop.local:8088/api/products` works from the Mac.
4. NetworkPolicies still enforced: a pod outside the gateway namespace can't reach the API.
5. `bootstrap.sh` completes with the smoke test through `localhost:8088`.
