# Testing — istio midstream

## Unit tests

- Standard Go testing (`testing.T`).
- Run: `make test`
- Golden files: update with `UPDATE_GOLDEN_FILES=true make test`

## Integration tests

- Run via Prow integration suite:

  ```bash
  prow/integ-suite-kind.sh <suite>
  ```

- Flaky tests: use `--istio.test.flaky` flag, document with upstream issue link.

## E2E tests

- OCP E2E run by Prow on `prow.ci.openshift.org`.
- Do not break upstream integration tests — all midstream changes must pass the upstream suite.

## Rules

- Never skip a failing test by commenting it out — open an issue and mark with `t.Skip("issue #N")`.
- OSSM-specific test scenarios should be in separate files with an `// OSSM-only:` header comment.
