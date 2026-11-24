import type { NextFunction, Request, Response } from 'express';
import { httpRequestDuration } from './registry.js';

export function metricsMiddleware(req: Request, res: Response, next: NextFunction): void {
  const stopTimer = httpRequestDuration.startTimer();
  res.on('finish', () => {
    stopTimer({
      method: req.method,
      // The route PATTERN (e.g. "/api/products/:id"), never the raw URL. Every distinct
      // label value creates a new time series in Prometheus; raw URLs with IDs or junk
      // paths from scanners would create unbounded series ("cardinality explosion").
      route: (req.route?.path as string | undefined) ?? 'unmatched',
      status_code: String(res.statusCode),
    });
  });
  next();
}
