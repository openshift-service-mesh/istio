# Submit PR — istio midstream

Before opening or updating a pull request in this repository, verify:

## 1. Label check (required)
Every PR must have **exactly one** of:
- `permanent-change` — the patch is OSSM-specific and will never go upstream
- `no-permanent-change` — the patch has been or will be submitted upstream; a revert is expected once merged
- `pending-upstream-sync` — the patch addresses an upstream issue that is not yet merged

Run `/sync-check` if you are unsure which label applies.

## 2. Upstream-first check
- If the change is a bug fix or feature applicable to upstream Istio, open an upstream PR **first**.
- Reference the upstream PR in your OSSM PR description.
- Do not apply `permanent-change` to changes that belong upstream.

## 3. OSSM-only comment convention
All code blocks that are OSSM-specific and not expected to exist upstream must be annotated:
```go
// OSSM-only: <JIRA-KEY> <one-line reason>
```

## 4. Checklist
- [ ] Exactly one PR label applied
- [ ] OSSM-only comments present on all OSSM-specific hunks
- [ ] Upstream PR opened (if applicable) and linked
- [ ] CI passing (`prow.ci.openshift.org`)
- [ ] No generated/protobuf files manually edited
