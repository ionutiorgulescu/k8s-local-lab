# k8s-lab

Learning project: production-grade Kubernetes on kind, later EKS. Plan: docs/phase-2-plan.md

## Rules
- Pin every version (kind node images, Helm charts, container images). Never use `latest`.
- Explain each command before running it; I'm learning, not just getting it done.
- All manifests must pass the `restricted` Pod Security Standard.
- Commit after each completed step with a descriptive message.
