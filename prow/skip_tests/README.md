# Skip Tests Configuration

The files `skip_tests_full.yaml` and `skip_tests_smoke.yaml` define which Istio integration tests should be skipped for this branch in downstream and midstream CI.

Prow jobs (midstream PR gating) and Jenkins jobs (downstream testing) use these files with the parser to determine which tests should be skipped during test execution (full or smoke).

## YAML Structure

```yaml
test_suites:
  <suite_name>:              # pilot, security, ambient, telemetry, or helm
    skip_tests:
      - name: "TestName"
        reason: "Why this test is skipped"
        skip_in: ['midstream_sail', 'midstream_helm', 'downstream']
    skip_subsuites:
      - name: "subsuite_name"
        reason: "Why this subsuite is skipped"
        skip_in: ['midstream_sail']
    run_tests_only: []
```

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | Yes | Test or subsuite name |
| `reason` | Yes | Explanation why it's skipped |
| `skip_in` | Yes | Where to skip: `midstream_sail`, `midstream_helm`, `downstream` (or combination) |

## Usage with Parser

Download and run the parser from [ci-utils](https://github.com/openshift-service-mesh/ci-utils):

```bash
# Download parser
curl -sLO https://raw.githubusercontent.com/openshift-service-mesh/ci-utils/main/skip_tests/parse-test-config.sh
chmod +x parse-test-config.sh

# Parse and run tests (full suite)
eval $(./parse-test-config.sh skip_tests_full.yaml <suite> <stream>)
integ-suite-ocp.sh "$SKIP_PARSER_SUITE" "$SKIP_PARSER_SKIP_TESTS" "$SKIP_PARSER_SKIP_SUBSUITES" "$SKIP_PARSER_RUN_TESTS_ONLY"

# Or for smoke tests
eval $(./parse-test-config.sh skip_tests_smoke.yaml <suite> <stream>)
integ-suite-ocp.sh "$SKIP_PARSER_SUITE" "$SKIP_PARSER_SKIP_TESTS" "$SKIP_PARSER_SKIP_SUBSUITES" "$SKIP_PARSER_RUN_TESTS_ONLY"
```

**Parameters:**
- `suite`: `pilot`, `security`, `ambient`, `telemetry`, or `helm`
- `stream`: `midstream_sail`, `midstream_helm`, or `downstream`

## Example

```bash
# Run full security tests in midstream_sail
eval $(./parse-test-config.sh skip_tests_full.yaml security midstream_sail)
integ-suite-ocp.sh "$SKIP_PARSER_SUITE" "$SKIP_PARSER_SKIP_TESTS" "$SKIP_PARSER_SKIP_SUBSUITES" "$SKIP_PARSER_RUN_TESTS_ONLY"

# Run smoke pilot tests in downstream
eval $(./parse-test-config.sh skip_tests_smoke.yaml pilot downstream)
integ-suite-ocp.sh "$SKIP_PARSER_SUITE" "$SKIP_PARSER_SKIP_TESTS" "$SKIP_PARSER_SKIP_SUBSUITES" "$SKIP_PARSER_RUN_TESTS_ONLY"
```
