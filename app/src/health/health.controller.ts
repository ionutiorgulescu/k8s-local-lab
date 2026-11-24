import { Controller, Get, ServiceUnavailableException } from '@nestjs/common';
import { DatabaseService } from '../database/database.service.js';
import { LifecycleService } from '../lifecycle/lifecycle.service.js';

@Controller()
export class HealthController {
  constructor(
    private readonly db: DatabaseService,
    private readonly lifecycle: LifecycleService,
  ) {}

  // Liveness: "is this process alive?" If this fails, the kubelet RESTARTS the container.
  // It must not check the database: if Postgres goes down, restarting every API pod
  // fixes nothing and makes recovery slower (all pods restarting at once when it returns).
  @Get('healthz')
  healthz() {
    return { status: 'ok' };
  }

  // Readiness: "can this pod serve traffic right now?" If this fails, the pod is REMOVED
  // from the Service's endpoints (no traffic), but it is not restarted. When the database
  // comes back, it turns ready again by itself.
  @Get('readyz')
  async readyz() {
    if (this.lifecycle.shuttingDown) {
      throw new ServiceUnavailableException('shutting down');
    }
    if (!(await this.db.isReady())) {
      throw new ServiceUnavailableException('database not ready');
    }
    return { status: 'ready' };
  }
}
