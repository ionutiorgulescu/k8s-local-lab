import { readFileSync } from 'node:fs';
import { Controller, Get } from '@nestjs/common';

// The version from package.json, read once at startup. package.json is copied into the
// image next to dist/ (see the Dockerfile), so this is the version of the running image.
// Path: dist/version/version.controller.js -> ../../package.json
const { version } = JSON.parse(
  readFileSync(new URL('../../package.json', import.meta.url), 'utf8'),
) as { version: string };

@Controller('api/version')
export class VersionController {
  // Reachable through the gateway (the HTTPRoute forwards /api/*), so you can check which
  // version is serving, e.g. during a rolling update.
  @Get()
  get() {
    return { version };
  }
}
