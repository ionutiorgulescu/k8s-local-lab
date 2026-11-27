import { Module } from '@nestjs/common';
import { DatabaseService } from './database/database.service.js';
import { HealthController } from './health/health.controller.js';
import { LifecycleService } from './lifecycle/lifecycle.service.js';
import { MetricsController } from './metrics/metrics.controller.js';
import { ProductsController } from './products/products.controller.js';
import { VersionController } from './version/version.controller.js';

@Module({
  controllers: [HealthController, ProductsController, MetricsController, VersionController],
  providers: [DatabaseService, LifecycleService],
})
export class AppModule {}
