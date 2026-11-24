# Phase 2: Kubernetes Core on kind

Goal: deploy a small API + Postgres app on a local multi-node kind cluster, with production habits
(security contexts, probes, resource requests, autoscaling, network isolation, RBAC) built in from the start.

Where this plan says **pin**, look up the current release and write the exact version into your files.
Unpinned versions are the most common reason a lab that worked last month breaks today.

Commit after every step.

---

## Step 0: Tools and repo

Install:

- Docker (Docker Desktop, OrbStack, or Docker Engine on Linux), with at least 8 GB RAM allocated
- `kind`, `kubectl`, `helm`, `cilium` CLI
- `k9s` (optional, recommended terminal UI)

Repo layout:

```
k8s-local-lab/
├── app/            # API source code + Dockerfile
├── cluster/        # kind config, cluster bootstrap scripts
├── k8s/            # Kubernetes manifests (later: a Helm chart)
└── docs/           # notes, diagrams, findings
```

**Verify:** `docker version`, `kind version`, `kubectl version --client`, `helm version`, `cilium version --client` all succeed.

---

## Step 1: Multi-node cluster without the default CNI

kind's built-in CNI does not enforce NetworkPolicies, so disable it and install Cilium.

`cluster/kind.yaml`:

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab
networking:
  disableDefaultCNI: true
nodes:
  - role: control-plane
    image: kindest/node:v1.XX.Y   # pin: match a Kubernetes version in EKS standard support
  - role: worker
    image: kindest/node:v1.XX.Y
  - role: worker
    image: kindest/node:v1.XX.Y
```

```bash
kind create cluster --config cluster/kind.yaml
kubectl get nodes                    # NotReady is expected: no CNI yet

cilium install --version <pinned>    # the CLI detects kind automatically
cilium status --wait
kubectl get nodes                    # now Ready
```

**Verify:** all three nodes are `Ready`.

---

## Step 2: metrics-server

Needed for `kubectl top` and the Horizontal Pod Autoscaler.

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm install metrics-server metrics-server/metrics-server \
  -n kube-system --version <pinned> \
  --set args={--kubelet-insecure-tls}   # kind only: kubelets use self-signed certs
```

**Verify:** `kubectl top nodes` returns numbers after about a minute.

---

## Step 3: Production-shaped app image

Write a small API (any language) with:

- `/healthz` — process is alive. Must **not** check the database; otherwise a DB outage restarts every pod.
- `/readyz` — pod can serve traffic. **Does** check the database connection.
- `/metrics` — Prometheus metrics (used in Phase 4).
- `/api/products` — a real endpoint that reads from Postgres.
- Graceful shutdown on SIGTERM: stop accepting new requests, finish in-flight ones.

Dockerfile requirements: multi-stage build, small base image (distroless or alpine), non-root user.

```bash
docker build -t shop-api:0.1.0 app/
kind load docker-image shop-api:0.1.0 --name lab
```

Never use the `latest` tag.

**Verify:** `docker run --rm -p 8080:8080 shop-api:0.1.0` starts and `/healthz` responds.

---

## Step 4: Namespace with Pod Security enforcement

`k8s/00-namespace.yaml`:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: shop
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/warn: restricted
```

Create the DB password imperatively so it never lands in Git (Phase 6 replaces this with External Secrets):

```bash
kubectl apply -f k8s/00-namespace.yaml
kubectl -n shop create secret generic postgres-credentials \
  --from-literal=password="$(openssl rand -base64 24)"
```

---

## Step 5: Postgres as a StatefulSet

Hand-written once to learn stable identity, headless Services, and `volumeClaimTemplates`.
(In real clusters: an operator like CloudNativePG, or a managed DB like RDS.)

`k8s/10-postgres.yaml`:

```yaml
apiVersion: v1
kind: Service
metadata: { name: postgres, namespace: shop }
spec:
  clusterIP: None
  selector: { app: postgres }
  ports: [{ name: pg, port: 5432 }]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: postgres, namespace: shop }
spec:
  serviceName: postgres
  replicas: 1
  selector: { matchLabels: { app: postgres } }
  template:
    metadata: { labels: { app: postgres } }
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 999
        fsGroup: 999
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: postgres
          image: postgres:17.X   # pin
          ports: [{ name: pg, containerPort: 5432 }]
          env:
            - { name: POSTGRES_DB, value: shop }
            - { name: PGDATA, value: /var/lib/postgresql/data/pgdata }
            - name: POSTGRES_PASSWORD
              valueFrom: { secretKeyRef: { name: postgres-credentials, key: password } }
          readinessProbe:
            exec: { command: ["pg_isready", "-U", "postgres"] }
            periodSeconds: 5
          resources:
            requests: { cpu: 100m, memory: 256Mi }
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts: [{ name: data, mountPath: /var/lib/postgresql/data }]
  volumeClaimTemplates:
    - metadata: { name: data }
      spec:
        accessModes: [ReadWriteOnce]
        resources: { requests: { storage: 2Gi } }
```

**Verify:** `kubectl -n shop delete pod postgres-0`; when it comes back, data is still there.

---

## Step 6: API Deployment

`k8s/20-api.yaml`:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: api, namespace: shop }
automountServiceAccountToken: false
---
apiVersion: v1
kind: ConfigMap
metadata: { name: api-config, namespace: shop }
data:
  DB_HOST: postgres
  DB_NAME: shop
  LOG_LEVEL: info
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: api, namespace: shop }
spec:
  replicas: 2
  selector: { matchLabels: { app: api } }
  strategy:
    rollingUpdate: { maxUnavailable: 0, maxSurge: 1 }
  template:
    metadata: { labels: { app: api } }
    spec:
      serviceAccountName: api
      terminationGracePeriodSeconds: 30
      securityContext:
        runAsNonRoot: true
        seccompProfile: { type: RuntimeDefault }
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: ScheduleAnyway
          labelSelector: { matchLabels: { app: api } }
      containers:
        - name: api
          image: shop-api:0.1.0
          imagePullPolicy: IfNotPresent
          ports: [{ name: http, containerPort: 8080 }]
          envFrom: [{ configMapRef: { name: api-config } }]
          env:
            - name: DB_PASSWORD
              valueFrom: { secretKeyRef: { name: postgres-credentials, key: password } }
          startupProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 2
            failureThreshold: 30
          readinessProbe:
            httpGet: { path: /readyz, port: http }
            periodSeconds: 5
          livenessProbe:
            httpGet: { path: /healthz, port: http }
            periodSeconds: 10
            failureThreshold: 3
          resources:
            requests: { cpu: 100m, memory: 128Mi }
            limits: { memory: 256Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
---
apiVersion: v1
kind: Service
metadata: { name: api, namespace: shop }
spec:
  selector: { app: api }
  ports: [{ name: http, port: 80, targetPort: http }]
```

Why these settings:

- `maxUnavailable: 0` — rolling updates never drop below current capacity.
- `topologySpreadConstraints` — replicas spread across nodes; losing one node doesn't take out all pods.
- Memory limit, no CPU limit — CPU limits cause throttling even when the node has spare CPU. Debated; be able to explain the tradeoff.
- `automountServiceAccountToken: false` — the app doesn't call the Kubernetes API, so it shouldn't carry credentials for it.

**Verify:** `kubectl -n shop port-forward svc/api 8080:80` then `curl localhost:8080/api/products`.

---

## Step 7: Expose with Gateway API (Envoy Gateway)

Use Gateway API rather than classic Ingress (ingress-nginx has been retired upstream).

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version <pinned> -n envoy-gateway-system --create-namespace
```

`k8s/30-gateway.yaml`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata: { name: eg }
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: { name: web, namespace: shop }
spec:
  gatewayClassName: eg
  listeners:
    - { name: http, protocol: HTTP, port: 80 }
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: { name: api, namespace: shop }
spec:
  parentRefs: [{ name: web }]
  hostnames: ["shop.local"]
  rules:
    - matches: [{ path: { type: PathPrefix, value: /api } }]
      backendRefs: [{ name: api, port: 80 }]
```

kind has no cloud load balancer. Either run `cloud-provider-kind` on your host, or port-forward:

```bash
SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=web -o name)
kubectl -n envoy-gateway-system port-forward $SVC 8888:80
curl -H "Host: shop.local" localhost:8888/api/products
```

**Verify:** the curl returns products through the gateway.

---

## Step 8: Autoscaling and disruption budget

`k8s/40-scaling.yaml`:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: api, namespace: shop }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: api }
  minReplicas: 2
  maxReplicas: 6
  metrics:
    - type: Resource
      resource: { name: cpu, target: { type: Utilization, averageUtilization: 70 } }
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata: { name: api, namespace: shop }
spec:
  minAvailable: 1
  selector: { matchLabels: { app: api } }
```

**Verify:**

```bash
kubectl run -it --rm load --image=busybox -- \
  sh -c "while true; do wget -qO- http://api.shop/api/products; done"
kubectl -n shop get hpa -w     # in another terminal; watch replicas increase
```

(Phase 5 replaces this with proper k6 load tests.)

---

## Step 9: NetworkPolicies (default deny)

`k8s/50-netpol.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: default-deny-ingress, namespace: shop }
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: api-from-gateway, namespace: shop }
spec:
  podSelector: { matchLabels: { app: api } }
  ingress:
    - from:
        - namespaceSelector:
            matchLabels: { kubernetes.io/metadata.name: envoy-gateway-system }
      ports: [{ port: 8080 }]
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: postgres-from-api, namespace: shop }
spec:
  podSelector: { matchLabels: { app: postgres } }
  ingress:
    - from: [{ podSelector: { matchLabels: { app: api } } }]
      ports: [{ port: 5432 }]
```

**Verify:** requests through the gateway still work; a test pod in another namespace can't reach Postgres;
the busybox loop from Step 8 is now blocked.

Stretch: add default-deny **egress** too, and discover that you must explicitly allow DNS.

---

## Step 10: RBAC

Create a read-only `developer` Role in `shop`, bind it to a ServiceAccount named `dev`, then test:

```bash
kubectl auth can-i list pods   -n shop --as=system:serviceaccount:shop:dev   # yes
kubectl auth can-i delete pods -n shop --as=system:serviceaccount:shop:dev   # no
kubectl auth can-i get secrets -n shop --as=system:serviceaccount:shop:dev   # should be no
```

---

## Step 11: Break it on purpose

Do each one and write what you observed in `docs/`:

1. **Bad image tag** — watch `ImagePullBackOff`, recover with `kubectl rollout undo`.
2. **Database outage** — stop Postgres; pods should leave the Service endpoints but **not** restart.
3. **Out of memory** — set the memory limit too low, trigger `OOMKilled`, find it with `kubectl describe pod`.
4. **Node drain** — `kubectl drain` a worker and watch the PDB protect availability.
5. **Missing NetworkPolicy rule** — remove an allow policy and debug with `kubectl` and `cilium hubble observe`.
6. **Rolling update under traffic** — deploy a new version during load; zero failed requests. If not, fix graceful shutdown.

---

## Step 12: Package it

Convert `k8s/` into a Helm chart with `values.yaml`, plus `values-local.yaml` and `values-eks.yaml`.
Run `helm lint` and `helm template` as part of your workflow. Argo CD deploys this chart in Phase 3.

---

## Cleanup and rebuild

```bash
kind delete cluster --name lab
```

Final exercise: write `cluster/bootstrap.sh` that recreates the whole environment from scratch
(cluster, Cilium, metrics-server, Envoy Gateway, app). If you can't rebuild from the repo alone,
it isn't really automated yet.
