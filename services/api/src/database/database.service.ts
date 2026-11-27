import {
  Injectable,
  Logger,
  type OnApplicationBootstrap,
  type OnApplicationShutdown,
} from '@nestjs/common';
import pg from 'pg';

const SCHEMA_RETRY_MS = 5000;

@Injectable()
export class DatabaseService implements OnApplicationBootstrap, OnApplicationShutdown {
  private readonly logger = new Logger(DatabaseService.name);
  private schemaReady = false;
  private stopped = false;
  private retryTimer?: NodeJS.Timeout;

  // Settings come from env vars: DB_HOST and DB_NAME from the ConfigMap,
  // DB_PASSWORD from the Secret (Step 6).
  readonly pool = new pg.Pool({
    host: process.env.DB_HOST ?? 'localhost',
    port: Number(process.env.DB_PORT ?? 5432),
    database: process.env.DB_NAME ?? 'shop',
    user: process.env.DB_USER ?? 'postgres',
    password: process.env.DB_PASSWORD,
    max: 10,
    // Fail fast instead of hanging when Postgres is down, so probes and requests
    // get a quick answer.
    connectionTimeoutMillis: 2000,
    query_timeout: 2000,
  });

  constructor() {
    // If Postgres restarts, idle pooled connections emit 'error'. Without a listener,
    // Node treats that as an unhandled error and the whole process crashes.
    this.pool.on('error', (err) => this.logger.warn(`idle connection error: ${err.message}`));
  }

  onApplicationBootstrap(): void {
    // Deliberately not awaited: the app must start (and pass /healthz) even while the
    // database is unreachable. /readyz stays failing until this succeeds.
    void this.initSchema();
  }

  // Creates the table and sample data if missing; retries until Postgres is reachable.
  // Fine for a lab. In production, schema migrations run as a separate step
  // (a Kubernetes Job or a CI stage), not inside every replica at startup.
  private async initSchema(): Promise<void> {
    try {
      await this.pool.query(`
        CREATE TABLE IF NOT EXISTS products (
          id          SERIAL PRIMARY KEY,
          name        TEXT NOT NULL UNIQUE,
          price_cents INTEGER NOT NULL
        )`);
      // ON CONFLICT: several replicas may run this at the same time; no duplicates.
      await this.pool.query(`
        INSERT INTO products (name, price_cents) VALUES
          ('Keyboard', 4999), ('Mouse', 1999), ('Monitor', 18999)
        ON CONFLICT (name) DO NOTHING`);
      this.schemaReady = true;
      this.logger.log('database schema ready');
    } catch (err) {
      if (this.stopped) return; // shutting down: don't schedule another retry
      // Connection errors (e.g. ECONNREFUSED) can have an empty message; fall back to the code.
      const e = err as Error & { code?: string };
      this.logger.warn(
        `database not ready (${e.message || e.code}); retrying in ${SCHEMA_RETRY_MS / 1000}s`,
      );
      this.retryTimer = setTimeout(() => void this.initSchema(), SCHEMA_RETRY_MS);
    }
  }

  // Used by /readyz: can this pod serve /api/products right now?
  async isReady(): Promise<boolean> {
    if (!this.schemaReady) return false;
    try {
      await this.pool.query('SELECT 1');
      return true;
    } catch {
      return false;
    }
  }

  // Runs last in the shutdown sequence, after the HTTP server has finished in-flight
  // requests. (onModuleDestroy would run too early: before the server closes.)
  async onApplicationShutdown(): Promise<void> {
    this.stopped = true;
    clearTimeout(this.retryTimer);
    await this.pool.end();
    this.logger.log('database pool closed');
  }
}
