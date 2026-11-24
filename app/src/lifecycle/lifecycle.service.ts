import { Injectable, Logger, type BeforeApplicationShutdown } from '@nestjs/common';

@Injectable()
export class LifecycleService implements BeforeApplicationShutdown {
  private readonly logger = new Logger(LifecycleService.name);
  shuttingDown = false;

  // Why wait before closing the server?
  // When Kubernetes deletes a pod, two things happen at the same time:
  //   a) the kubelet sends SIGTERM to the container
  //   b) the pod is removed from the Service's endpoints, and every node's kube-proxy
  //      (or Cilium, or a gateway) updates its routing
  // (b) takes a moment. If the app stopped accepting connections immediately on (a),
  // requests still routed to it during that moment would fail. So: fail /readyz,
  // keep serving for a few seconds, and only then close the server.
  async beforeApplicationShutdown(signal?: string): Promise<void> {
    this.shuttingDown = true;
    const delayMs = Number(process.env.SHUTDOWN_DELAY_MS ?? 5000);
    this.logger.log(`received ${signal}; failing readiness, closing in ${delayMs}ms`);
    await new Promise((resolve) => setTimeout(resolve, delayMs));
  }
}
