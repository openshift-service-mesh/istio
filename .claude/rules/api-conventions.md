# API Conventions — istio midstream

## PR labels (required)

Every PR must carry **exactly one** label (see [CONTRIBUTING.md](../CONTRIBUTING.md) for full details):

- `permanent-change` — OSSM-specific change, never going upstream; must be cherry-picked to all future minor release branches.
- `no-permanent-change` — Automator sync PR for a specific release branch; will **not** be cherry-picked to next minor release branches.
- `pending-upstream-sync` — Change already merged into a supported upstream Istio branch but not yet present in the relevant midstream release branches.

## Upstream-first rule

Bug fixes and features that belong in upstream Istio must have an upstream PR opened **first**. Do not merge OSSM patches for upstream issues without a tracking upstream PR.

## OSSM-only comment convention

Every code block that is OSSM-specific must be annotated:

```go
// OSSM-only: <JIRA-KEY> <one-line reason>
```

This annotation is mandatory — it is how the sync-auditor and human reviewers identify divergence points.

## Generated files

- Never edit `*.pb.go`, `*.gen.go`, or files under `vendor/` manually.
- Re-run the appropriate `make generate` target and commit the output.
