# Istio Midstream Agent Instructions

This repository is the Red Hat midstream fork of [Istio](https://github.com/istio/istio),
maintained for OpenShift Service Mesh (OSSM).

## Key Documentation

- **[Upstream Relationship](docs/upstream.md)** -- How this repository relates to
  upstream Istio, branch mapping, contribution workflow, and sync process.

## Domain Knowledge

The [`.github/.copilot/domain_knowledge/`](.github/.copilot/domain_knowledge/) directory is
the primary AI knowledge base for this repository. Consult these files before making
assumptions about internals.

| File | Description |
|------|-------------|
| [`integration_test_framework.md`](.github/.copilot/domain_knowledge/integration_test_framework.md) | Integration test framework (`pkg/test/framework`): environment setup, resource management, multi-cluster patterns |
| [`istio_analysis_messages.md`](.github/.copilot/domain_knowledge/istio_analysis_messages.md) | Istio analyzer messages: what they are, how to access them, and how to add new analyzers |
| [`istio_tags_and_revisions.md`](.github/.copilot/domain_knowledge/istio_tags_and_revisions.md) | Tags and revisions: role in xDS orchestration, create/update/delete lifecycle |
| [`istioctl_commands.md`](.github/.copilot/domain_knowledge/istioctl_commands.md) | `istioctl` command structure and configuration sources |
| [`krt_package.md`](.github/.copilot/domain_knowledge/krt_package.md) | `krt` (Kubernetes Declarative Controller Runtime): declarative controller framework, transformation logic, resource relationships |
| [`pilot_push_context.md`](.github/.copilot/domain_knowledge/pilot_push_context.md) | Pilot `PushContext`: construction and transformation into xDS messages for Envoy |

## Repository Context

- **Upstream**: https://github.com/istio/istio
- **Midstream**: https://github.com/openshift-service-mesh/istio
- Changes in this fork are OSSM-specific patches layered on top of upstream Istio.
- Prefer landing changes upstream first; only commit OSSM-specific work directly here.

## Development

- Follow the upstream Istio coding conventions and project structure.
- Keep OSSM-specific patches minimal and clearly marked with JIRA references.
- PRs are gated by prow CI.

## PR Labels

Every PR to this repository requires one of the following labels (see [CONTRIBUTING.md](CONTRIBUTING.md)):

- **`permanent-change`** — OSSM-specific change that stays permanently in the midstream and must be cherry-picked to new release branches (OpenShift features, customizations, compliance patches).
- **`no-permanent-change`** — Temporary or experimental change that will be removed or replaced by upstream sync; must NOT be cherry-picked to release branches.
- **`pending-upstream-sync`** — Change awaiting upstream sync; cherry-pick to release branches only until the equivalent lands from upstream Istio.

Exactly one label is required per PR. The label check CI job enforces this and will fail the PR if missing or if more than one is applied. When generating or reviewing a PR, always determine and apply the correct label before submitting.
