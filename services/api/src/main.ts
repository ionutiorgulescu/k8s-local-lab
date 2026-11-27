import 'reflect-metadata';
import { Logger, type LogLevel } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { AppModule } from './app.module.js';
import { metricsMiddleware } from './metrics/metrics.middleware.js';

// LOG_LEVEL comes from the ConfigMap in Step 6. Each level includes the ones above it.
const LOG_LEVELS: Record<string, LogLevel[]> = {
  error: ['fatal', 'error'],
  warn: ['fatal', 'error', 'warn'],
  info: ['fatal', 'error', 'warn', 'log'],
  debug: ['fatal', 'error', 'warn', 'log', 'debug'],
  verbose: ['fatal', 'error', 'warn', 'log', 'debug', 'verbose'],
};

async function bootstrap(): Promise<void> {
  const level = (process.env.LOG_LEVEL ?? 'info').toLowerCase();
  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    logger: LOG_LEVELS[level] ?? LOG_LEVELS.info,
  });

  // Don't advertise the framework in every response ("X-Powered-By: Express").
  app.disable('x-powered-by');

  // Time every request for the /metrics histogram.
  app.use(metricsMiddleware);

  // Graceful shutdown. Kubernetes stops a pod by sending SIGTERM, then SIGKILL after
  // terminationGracePeriodSeconds (30s by default). This makes Nest catch SIGTERM and
  // run the shutdown sequence instead of dying mid-request:
  //   1. LifecycleService.beforeApplicationShutdown: /readyz starts failing, then waits
  //      a few seconds so Kubernetes can stop routing new traffic to this pod.
  //   2. The HTTP server closes: no new connections; in-flight requests are allowed to finish.
  //   3. DatabaseService.onApplicationShutdown: the Postgres pool closes.
  //
  // useProcessExit: after shutdown, exit with process.exit(0). Without it, Nest re-sends
  // the signal to itself to terminate, but in a container the app is PID 1, and the
  // kernel ignores signals to PID 1 that have no handler. The process would then only
  // exit if nothing else kept Node busy, or hang until SIGKILL.
  app.enableShutdownHooks(['SIGTERM', 'SIGINT'], { useProcessExit: true });

  const port = Number(process.env.PORT ?? 8080);
  // 0.0.0.0, not localhost: inside a container, localhost is unreachable from outside the pod.
  await app.listen(port, '0.0.0.0');
  Logger.log(`listening on :${port}`, 'Bootstrap');
}

await bootstrap();
