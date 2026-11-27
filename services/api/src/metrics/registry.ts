// The official Prometheus client for Node.js (formerly published as "prom-client").
import { Histogram, Registry, collectDefaultMetrics } from '@prometheus-io/client';

export const registry = new Registry();

// Node.js process metrics: CPU, memory, event loop lag, garbage collection, and more.
collectDefaultMetrics({ register: registry });

// One histogram gives request rate, error rate and latency percentiles: the "RED" metrics
// you'll graph in Phase 4.
export const httpRequestDuration = new Histogram({
  name: 'http_request_duration_seconds',
  help: 'HTTP request duration in seconds',
  labelNames: ['method', 'route', 'status_code'] as const,
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5],
  registers: [registry],
});
