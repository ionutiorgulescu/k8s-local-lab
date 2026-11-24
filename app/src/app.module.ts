import { Module } from '@nestjs/common';
import { DatabaseService } from './database/database.service.js';
import { HealthController } from './health/health.controller.js';
import { LifecycleService } from './lifecycle/lifecycle.service.js';
import { MetricsController } from './metrics/metrics.controller.js';
import { ProductsController } from './products/products.controller.js';

@Module({
  controllers: [HealthController, ProductsController, MetricsController],
  providers: [DatabaseService, LifecycleService],
})
export class AppModule {}
