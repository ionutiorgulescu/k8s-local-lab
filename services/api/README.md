# shop-api

Small NestJS API backed by Postgres, built for the Phase 2 Kubernetes lab. 

## Endpoints

| Path            | Purpose | Checks the DB? |
|-----------------|---------|----------------|
| `/healthz`      | Liveness: process is alive. Failing → container restarted. | No, on purpose |
| `/readyz`       | Readiness: can serve traffic. Failing → removed from Service endpoints. Also fails during shutdown. | Yes |
| `/metrics`      | Prometheus metrics (Node.js runtime + `http_request_duration_seconds`). | No |
| `/api/products` | Lists products from Postgres. Table and sample rows are created on startup. | Yes |

## Configuration (environment variables)

| Variable            | Default     | Source in Kubernetes |
|---------------------|-------------|----------------------|
| `PORT`              | `8080`      | |
| `DB_HOST`           | `localhost` | ConfigMap |
| `DB_PORT`           | `5432`      | |
| `DB_NAME`           | `shop`      | ConfigMap |
| `DB_USER`           | `postgres`  | |
| `DB_PASSWORD`       | (none)      | Secret |
| `LOG_LEVEL`         | `info`      | ConfigMap (`error`, `warn`, `info`, `debug`, `verbose`) |
| `SHUTDOWN_DELAY_MS` | `5000`      | How long to keep serving after SIGTERM before closing |

## Graceful shutdown

On SIGTERM: `/readyz` starts returning 503 → wait `SHUTDOWN_DELAY_MS` (so Kubernetes
stops routing new requests here) → HTTP server stops accepting connections and lets
in-flight requests finish → Postgres pool closes → `process.exit(0)`.

The explicit exit matters because in a container the app is PID 1, and the kernel ignores
signals to PID 1 that have no handler. Exit code 0 means a clean shutdown; 137 (128 + 9)
means it was killed with SIGKILL because the grace period ran out.

## Build and run

```bash
cd app && npm install          # once: creates package-lock.json
docker build -t shop-api:dev services/api/
docker run --rm -p 8080:8080 shop-api:0.1.0
```
