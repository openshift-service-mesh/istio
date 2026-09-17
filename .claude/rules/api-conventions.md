# API Conventions — istio midstream

## PR labels (required)

Every PR must carry **exactly one** label:

- `permanent-change` — OSSM-specific, never going upstream
- `no-permanent-change` — already upstream or will be reverted once merged
- `pending-upstream-sync` — upstream PR open or planned

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
