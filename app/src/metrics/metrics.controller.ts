import { Controller, Get, Header } from '@nestjs/common';
import { registry } from './registry.js';

@Controller('metrics')
export class MetricsController {
  // Prometheus scrapes this endpoint (Phase 4).
  @Get()
  @Header('Content-Type', registry.contentType)
  metrics(): Promise<string> {
    return registry.metrics();
  }
}
