#!/bin/bash

# Copyright 2019 Istio Authors
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# This script is used to run the integration tests on OpenShift.
# Usage: ./integ-suite-ocp.sh [TEST_SUITE] [SKIP_TESTS] [SKIP_SUITE] [SPECIFIC_TESTS]
# Example: ./integ-suite-ocp.sh telemetry "TestAuthZCheck|TestRevisionTags" "tracing/zipkin|policy" "TestAccessLogs|TestAccessLogsFilter"
#
# Parameters can also be set via environment variables:
#   TEST_SUITE: The test suite to run. Default is "pilot". Available options are "pilot", "security", "telemetry", "helm", "ambient".
#   SKIP_TESTS: The tests to skip. Default is "".                          e.g. "TestAuthZCheck|TestRevisionTags"
#   SKIP_SUITE: The test suites under main suite to skip. Default is "".   e.g. "tracing/zipkin|policy"
#   SPECIFIC_TESTS: The specific tests ONLY to run. Default is "".         e.g. "TestAccessLogs|TestAccessLogsFilter"
#   TOPOLOGY: Cluster topology mode. Default is "SINGLE_CLUSTER". Options: "SINGLE_CLUSTER", "MULTICLUSTER", "AMBIENT_MULTICLUSTER"
#   CLUSTER_TOPOLOGY_CONFIG: Path to topology JSON file. Default varies by TOPOLOGY setting.
#
# Single-cluster examples:
#   ./integ-suite-ocp.sh telemetry                                                            # Run all telemetry tests
#   ./integ-suite-ocp.sh telemetry "" "" "TestAccessLogs|TestAccessLogsFilter"                # Run only specific tests
#   ./integ-suite-ocp.sh telemetry "" "tracing/zipkin" "TestAccessLogs|TestAccessLogsFilter"  # Run specific tests but skip if in tracing/zipkin suite
#   SPECIFIC_TESTS="TestAccessLogs|TestAccessLogsFilter" ./integ-suite-ocp.sh telemetry       # Same as above, using env var
#   SKIP_TESTS="TestAuthZCheck|TestRevisionTags" ./integ-suite-ocp.sh pilot                   # Skip specific tests
#   SKIP_SUITE="tracing/zipkin|policy" ./integ-suite-ocp.sh telemetry                         # Skip specific suites
#
# Multicluster examples (requires KUBECONFIG with multiple cluster contexts):
#   export KUBECONFIG=/path/to/primary.kubeconfig:/path/to/remote.kubeconfig
#   TOPOLOGY=MULTICLUSTER ./integ-suite-ocp.sh pilot                                          # Run pilot tests across multiple clusters
#   TOPOLOGY=AMBIENT_MULTICLUSTER ./integ-suite-ocp.sh ambient                                # Run ambient multicluster tests
#   TOPOLOGY=MULTICLUSTER CLUSTER_TOPOLOGY_CONFIG=prow/config/topology/ocp/custom.json ./integ-suite-ocp.sh pilot  # Use custom topology
#   TOPOLOGY=MULTICLUSTER ./integ-suite-ocp.sh security                                       # Run security tests in multicluster mode
#
# Note: If using default topology files and fewer clusters are available than defined in the topology,
#       a dynamic topology will be auto-generated to match the available clusters.
#       Example: 2 clusters available, but multicluster.json defines 3 → auto-generates 2-cluster topology
#
# TODO: Use the same arguments as integ-suite.kind.sh uses

WD=$(dirname "$0")
ROOT=$(dirname "$WD")
WD=$(cd "$WD"; pwd)
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
TEST_SUITE="${1:-${TEST_SUITE:-"pilot"}}"
SKIP_TESTS="${2:-${SKIP_TESTS:-""}}"
SKIP_SUITE="${3:-${SKIP_SUITE:-""}}"
SPECIFIC_TESTS="${4:-${SPECIFIC_TESTS:-""}}"
SKIP_SETUP="${SKIP_SETUP:-"false"}"
INSTALL_METALLB="${INSTALL_METALLB:-"false"}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-"sail-operator"}"
CONTROL_PLANE_SOURCE="${CONTROL_PLANE_SOURCE:-"istio"}"
INSTALL_SAIL_OPERATOR="${INSTALL_SAIL_OPERATOR:-"false"}"
TRUSTED_ZTUNNEL_NAMESPACE="${TRUSTED_ZTUNNEL_NAMESPACE:-"istio-system"}"
AMBIENT="${AMBIENT:="false"}"
FIPS="${FIPS:="false"}"
TEST_HUB="${TEST_HUB:="image-registry.openshift-image-registry.svc:5000/istio-images"}"
DEPLOY_GATEWAY_API="false"
IBM="${IBM:-"false"}"
TOPOLOGY="${TOPOLOGY:-"SINGLE_CLUSTER"}"
CLUSTER_TOPOLOGY_CONFIG="${CLUSTER_TOPOLOGY_CONFIG:-""}"

# Important: SKIP_TEST_RUN is a workaround until downstream tests can be executed by using this script. 
# To execute the tests in downstream, set SKIP_TEST_RUN to true
# Jira: https://issues.redhat.com/browse/OSSM-8029
SKIP_TEST_RUN="${SKIP_TEST_RUN:-"false"}"
# TEST_OUTPUT_FORMAT set the output format for the test result. Currently only supports: not set and junit
# If you are executing locally you will need to install before the go-junit-report package
TEST_OUTPUT_FORMAT="${TEST_OUTPUT_FORMAT:-"junit"}"

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

check_cluster_operators() {
  # Check if jq is installed
  if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for the cluster operator health check. Please install jq."
    exit 1
  fi

  local contexts=("")
  if [[ "${TOPOLOGY}" != "SINGLE_CLUSTER" ]] && [[ ${#cluster_contexts[@]} -gt 0 ]]; then
    contexts=("${cluster_contexts[@]}")
  fi

  for ctx in "${contexts[@]}"; do
    local ctx_flag=""
    local ctx_display="current context"
    if [[ -n "${ctx}" ]]; then
      ctx_flag="--context=${ctx}"
      ctx_display="${ctx}"
    fi

    local timeout_seconds=600 # 10 minutes
    echo "Validating OpenShift cluster operators are stable on ${ctx_display}..."
    local end_time=$(( $(date +%s) + timeout_seconds ))

    local stable=false
    while [ "$(date +%s)" -lt $end_time ]; do
      local unstable_operators
      unstable_operators=$(oc ${ctx_flag} get clusteroperator -o json | jq '[.items[] | select(.status.conditions[] | (.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True"))] | length')

      if [[ $unstable_operators -eq 0 ]]; then
        echo "All cluster operators are stable on ${ctx_display}."
        stable=true
        break
      fi

      echo -n "."
      sleep 15
    done

    if [[ "${stable}" != "true" ]]; then
      echo "ERROR: Timeout reached. Not all cluster operators are stable on ${ctx_display}."
      oc ${ctx_flag} get clusteroperator
      exit 1
    fi
  done
}

# shellcheck source=common/scripts/kind_provisioner.sh
source "${ROOT}/prow/setup/ocp_setup.sh"

# Override build_images() from lib.sh with OCP-specific version
# This must be defined AFTER sourcing to override the lib.sh version
function build_images() {
    # Build just the images needed for tests
    targets="docker.pilot docker.proxyv2 docker.install-cni "

    # Integration tests are always running on local architecture (no cross compiling), so find out what that is.
    arch="linux/amd64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="linux/arm64"
    fi

    # use ubuntu:noble to test vms by default
    nonDistrolessTargets="docker.app docker.app_sidecar_ubuntu_noble docker.ext-authz docker.ztunnel "

    # Build and push to first cluster registry (HUB)
    if [[ "${VARIANT:-default}" == "distroless" ]]; then
        echo "Building distroless images"
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="distroless" DOCKER_TARGETS="${targets}" make dockerx.pushx
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="default" DOCKER_TARGETS="${nonDistrolessTargets}" make dockerx.pushx
    else
        echo "Building default images"
        DOCKER_ARCHITECTURES="${arch}"  DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" make dockerx.pushx
    fi

    # Push to all additional cluster registries
    if [[ -n "${CLUSTER_REGISTRY_URLS:-}" ]] && [[ ${#CLUSTER_REGISTRY_URLS[@]} -gt 1 ]]; then
        echo ""
        echo "=== Pushing images to additional clusters ==="

        # List of image names that were built
        local images=("pilot" "proxyv2" "install-cni" "app" "app_sidecar_ubuntu_noble" "ext-authz" "ztunnel")

        # Skip first registry (already pushed during build)
        for i in $(seq 1 $((${#CLUSTER_REGISTRY_URLS[@]} - 1))); do
            local target_registry="${CLUSTER_REGISTRY_URLS[i]}"
            echo ""
            echo "Pushing to cluster $((i+1)): ${target_registry}"

            for image in "${images[@]}"; do
                local source_image="${HUB}/${image}:${TAG}"
                local target_image="${target_registry}/${image}:${TAG}"

                echo "  Copying ${image} to cluster $((i+1))..."
                # Use oc image mirror which handles authentication and TLS automatically
                if ! oc image mirror "${source_image}" "${target_image}" --keep-manifest-list --insecure=true 2>&1; then
                    echo "  Warning: Failed to mirror ${image} to ${target_registry}"
                fi
            done
        done

        echo ""
        echo "=== Image push completed for all ${#CLUSTER_REGISTRY_URLS[@]} clusters ==="
    fi
}

# Define the artifacts directory
ARTIFACTS_DIR="${ARTIFACT_DIR:-"${WD}/artifacts"}"
JUNIT_REPORT_DIR="${ARTIFACTS_DIR}/junit"

# Ensure artifacts directory exists
mkdir -p "${JUNIT_REPORT_DIR}"

# Set OCP-specific topology configuration file paths
if [[ "${TOPOLOGY}" == "MULTICLUSTER" ]] && [[ -z "${CLUSTER_TOPOLOGY_CONFIG}" ]]; then
  CLUSTER_TOPOLOGY_CONFIG="prow/config/topology/ocp/multicluster.json"
elif [[ "${TOPOLOGY}" == "AMBIENT_MULTICLUSTER" ]] && [[ -z "${CLUSTER_TOPOLOGY_CONFIG}" ]]; then
  CLUSTER_TOPOLOGY_CONFIG="prow/config/topology/ocp/ambient-multicluster.json"
fi

CLUSTER_TOPOLOGY_CONFIG_FILE="${ROOT}/${CLUSTER_TOPOLOGY_CONFIG}"

# Handle multicluster setup
if [[ "${TOPOLOGY}" != "SINGLE_CLUSTER" ]]; then
  echo "Setting up multicluster topology: ${TOPOLOGY}"

  # Normalize kubeconfig contexts FIRST to handle duplicate context names
  # This must be done before counting contexts or loading topology
  if [[ -n "${KUBECONFIG:-}" ]]; then
    # Create temporary minimal topology just to get cluster names for normalization
    if [[ -f "${CLUSTER_TOPOLOGY_CONFIG_FILE}" ]]; then
      echo "Pre-normalizing kubeconfig contexts..."
      # Extract cluster names from topology
      mapfile -t TEMP_CLUSTER_NAMES < <(jq -r '.[] | .clusterName' "${CLUSTER_TOPOLOGY_CONFIG_FILE}")
      export CLUSTER_NAMES=("${TEMP_CLUSTER_NAMES[@]}")

      # Normalize contexts to match cluster names from topology
      normalize_kubeconfig_contexts
    fi
  fi

  # Generate dynamic topology if the default file requires more clusters than available
  # Only auto-generate for default topology files (not custom user-specified files)
  if [[ "${CLUSTER_TOPOLOGY_CONFIG}" == "prow/config/topology/ocp/multicluster.json" ]] || [[ "${CLUSTER_TOPOLOGY_CONFIG}" == "prow/config/topology/ocp/ambient-multicluster.json" ]]; then
    # NOW get available contexts (after normalization - all contexts have unique names)
    mapfile -t AVAILABLE_CONTEXTS < <(kubectl config get-contexts -o name 2>/dev/null || true)
    NUM_AVAILABLE_CLUSTERS=${#AVAILABLE_CONTEXTS[@]}

    echo "Number of available contexts: ${NUM_AVAILABLE_CLUSTERS}"

    # Check if we need to generate a dynamic topology
    if [[ -f "${CLUSTER_TOPOLOGY_CONFIG_FILE}" ]]; then
      TOPOLOGY_CLUSTER_COUNT=$(jq '. | length' "${CLUSTER_TOPOLOGY_CONFIG_FILE}")

      if [[ ${NUM_AVAILABLE_CLUSTERS} -lt ${TOPOLOGY_CLUSTER_COUNT} ]]; then
        echo "Warning: Default topology requires ${TOPOLOGY_CLUSTER_COUNT} clusters, but only ${NUM_AVAILABLE_CLUSTERS} available in KUBECONFIG"
        echo "Generating dynamic topology based on available clusters..."
        generate_dynamic_topology "${NUM_AVAILABLE_CLUSTERS}" "${TOPOLOGY}"
        CLUSTER_TOPOLOGY_CONFIG_FILE="${ARTIFACTS_DIR}/dynamic-topology.json"
      fi
    fi
  fi

  # Load and validate topology (normalization already done above)
  load_cluster_topology "${CLUSTER_TOPOLOGY_CONFIG_FILE}"
  validate_ocp_multicluster_kubeconfigs

  # Setup runtime topology configuration
  setup_ocp_multicluster_topology "${CLUSTER_TOPOLOGY_CONFIG_FILE}"
  export INTEGRATION_TEST_TOPOLOGY_FILE="${ARTIFACTS_DIR}/topology-config.json"
  export INTEGRATION_TEST_KUBECONFIG=NONE
fi

# Install MetalLB if the flag is set
if [ "${INSTALL_METALLB}" == "true" ]; then
    echo "Installing MetalLB"
    deployMetalLB

# Run the setup only if MetalLB is not being installed and setup is not skipped
elif [ "${INSTALL_METALLB}" != "true" ] && [ "${SKIP_SETUP}" != "true" ]; then
    echo "Running full setup..."

    # Setup the internal registry for the OCP cluster
    setup_internal_registry

    # Build and push the images to the internal registry
    build_images

    # Install Sail Operator
    if [ "${INSTALL_SAIL_OPERATOR}" == "true" ]; then
        deploy_operator
    fi

else
    echo "Skipping the setup"
fi

# Check if the test run should be skipped
# This is a workaround until downstream tests can be executed by using this script.
# Jira: https://issues.redhat.com/browse/OSSM-8029
if [ "${SKIP_TEST_RUN}" == "true" ]; then
    echo "Skipping the test run"
    exit 0
fi

# Run the integration tests
echo "Running integration tests"

# Set gcr.io as mirror to docker.io/istio to be able to get images in downstream tests.
if [ "${TEST_HUB}" == "docker.io/istio" ]; then
    addGcrMirror
fi

# Check OCP version
if ! OCP_VERSION_FULL=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null); then
    echo "Failed to detect OpenShift version. Are you connected to a cluster?"
    exit 1
fi
OCP_VERSION_MINOR=$(echo "$OCP_VERSION_FULL" | cut -d. -f2)

# Compare versions
version_ge() {
    # Returns 0 if $1 >= $2
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$2" ]
}

# Starting from OCP 4.19, Gateway API CRDs comes pre-installed and could not be modified by the user.
# So for OCP version 4.19 and above, we're not deploying GW API CRDs.
if version_ge "$OCP_VERSION_MINOR" "19"; then
    echo "Openshift version 4.19 or above. Gateway API CRDs comes pre-installed with the cluster."
else
    echo "Openshift version below 4.19. Deploying Gateway API CRDs."
    DEPLOY_GATEWAY_API="true"
fi

# Set up test command and parameters
setup_junit_report() {
    export ISTIO_BIN="${GOPATH}/bin"
    echo "ISTIO_BIN: ${ISTIO_BIN}"

    JUNIT_REPORT=$(which go-junit-report 2>/dev/null)
    if [ -z "$JUNIT_REPORT" ]; then
        JUNIT_REPORT="${ISTIO_BIN}/go-junit-report"
    fi
    echo "JUNIT_REPORT: ${JUNIT_REPORT}"
}

# Prepare go list expression for skipping suites
if [[ -n "$SKIP_SUITE" ]]; then
  mapfile -t TEST_PATH < <(
    go list -tags=integ "./tests/integration/${TEST_SUITE}/..." |
    grep -vE "/(${SKIP_SUITE})$"
  )
else
  TEST_PATH=("./tests/integration/${TEST_SUITE}/...")
fi

# Build the base command and store it in an array
base_cmd=(
  "go" "test" "-p" "1" "-v" "-count=1" "-tags=integ" "-vet=off" "-timeout=60m"
  "${TEST_PATH[@]}"
  "--istio.test.ci"
  "--istio.test.pullpolicy=IfNotPresent"
  "--istio.test.work_dir=${ARTIFACTS_DIR}"
  "--istio.test.skipVM=true"
  "--istio.test.istio.enableCNI=true"
  "--istio.test.hub=${TEST_HUB}"
  "--istio.test.tag=${TAG}"
  "--istio.test.kube.deployGatewayAPI=${DEPLOY_GATEWAY_API}"
  "--istio.test.openshift"
)

# Add topology configuration for multicluster tests
if [[ "${TOPOLOGY}" != "SINGLE_CLUSTER" ]]; then
  base_cmd+=("--istio.test.kube.topology=${INTEGRATION_TEST_TOPOLOGY_FILE}")
fi

helm_values="global.platform=openshift"

# IBM specific modifications
if [ "${IBM}" == "true" ]; then
    base_cmd+=("--istio.test.skipTProxy=true")
fi

# Gateway Conformance Test related modifications
if [ "${TEST_SUITE}" == "pilot" ]; then
    # Until OCP 4.19 default CRDs has https://github.com/kubernetes-sigs/gateway-api/pull/3389 we need following patch
    git apply --verbose --reject --whitespace=fix --ignore-space-change ./prow/config/sail-operator/istio-gw-api-coredns-fix.patch
    # This flag we need to run the conformance test even if the CRDs are not matching with the desired ones in go.mod
    base_cmd+=("--istio.test.GatewayConformanceAllowCRDsMismatch=true")
    # Stops flaky runs in public clouds
    base_cmd+=("--istio.test.gatewayConformance.maxTimeToConsistency=300s")
fi

# If ambient mode executed, add "ambient" profile and args
if [[ "${AMBIENT}" == "true" || "${TEST_SUITE}" == *"ambient"* ]]; then
    base_cmd+=("--istio.test.ambient")
    # This flag we need to run the conformance test even if the CRDs are not matching with the desired ones in go.mod
    base_cmd+=("--istio.test.GatewayConformanceAllowCRDsMismatch=true")
    # Stops flaky runs in public clouds
    base_cmd+=("--istio.test.gatewayConformance.maxTimeToConsistency=300s")
    helm_values+=",pilot.trustedZtunnelNamespace=${TRUSTED_ZTUNNEL_NAMESPACE}"
    base_cmd+=("--istio.test.kube.ztunnelNamespace=${TRUSTED_ZTUNNEL_NAMESPACE}")

    # Add multinetwork flag for ambient multicluster tests
    if [[ "${TOPOLOGY}" == "AMBIENT_MULTICLUSTER" ]]; then
        base_cmd+=("--istio.test.ambient.multinetwork")
    fi

    # Set local gateway mode for Ambient execution on all clusters
    gw_contexts=("")
    if [[ "${TOPOLOGY}" != "SINGLE_CLUSTER" ]] && [[ ${#cluster_contexts[@]} -gt 0 ]]; then
        gw_contexts=("${cluster_contexts[@]}")
    fi
    for ctx in "${gw_contexts[@]}"; do
        ctx_flag="" ctx_display="current context"
        if [[ -n "${ctx}" ]]; then
            ctx_flag="--context=${ctx}"
            ctx_display="${ctx}"
        fi
        echo "Setting local gateway mode on ${ctx_display}"
        oc ${ctx_flag} patch networks.operator.openshift.io cluster --type=merge \
            -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
        routing_via_host=$(oc ${ctx_flag} get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}')
        if [ "${routing_via_host}" != "true" ]; then
            echo "Unable to set local gateway mode for Ambient execution on ${ctx_display}"
            exit 1
        fi
    done
fi

base_cmd+=("--istio.test.kube.helm.values=${helm_values}")

# Append sail operator setup script to base command
if [ "${CONTROL_PLANE_SOURCE}" == "sail" ]; then
    # Remove timeout 60m
    for i in "${!base_cmd[@]}"; do
        if [[ "${base_cmd[$i]}" == "-timeout="* ]]; then
            unset 'base_cmd[i]'
        fi
    done
    if [ "${FIPS}" == "true" ]; then
        base_cmd+=("-timeout=240m")
        base_cmd+=("--istio.test.fips")
    else
        base_cmd+=("-timeout=120m")
    fi

    # Add sail operator setup script
    SAIL_SETUP_SCRIPT="${WD}/setup/sail-operator-setup.sh"
    base_cmd+=("--istio.test.kube.deploy=false")
    base_cmd+=("--istio.test.kube.controlPlaneInstaller=${SAIL_SETUP_SCRIPT}")
fi

# Append specific tests flag if SPECIFIC_TESTS is set, e.g.: "TestTraffic|TestServices"
if [ -n "${SPECIFIC_TESTS}" ]; then
    base_cmd+=("-run" "${SPECIFIC_TESTS}")
fi

# Append skip tests flag if SKIP_TESTS is set
if [ -n "${SKIP_TESTS}" ]; then
    base_cmd+=("-skip" "${SKIP_TESTS}")
fi

# Execute the command and handle junit output
if [ "${TEST_OUTPUT_FORMAT}" == "junit" ]; then
    echo "A junit report file will be generated"
    setup_junit_report
    "${base_cmd[@]}" 2>&1 | tee >( "${JUNIT_REPORT}" > "${ARTIFACTS_DIR}/junit/junit.xml" )
    test_status=${PIPESTATUS[0]}

elif [ "${TEST_OUTPUT_FORMAT}" == "gotestsum" ]; then
    echo "Using gotestsum to run tests and generate junit report"
    # Install gotestsum if not already available
    if ! command -v gotestsum &>/dev/null; then
        go install gotest.tools/gotestsum@latest
        # Get Go binary path (prefer GOBIN, fallback to GOPATH/bin)
        gobin=$(go env GOBIN 2>/dev/null)
        if [ -z "$gobin" ]; then
            gobin="$(go env GOPATH)/bin"
        fi
        export PATH="$gobin:$PATH"
    fi

    mkdir -p "${JUNIT_REPORT_DIR}"

    gotestsum \
      -f testname \
      --junitfile-project-name istio \
      --junitfile "${JUNIT_REPORT_DIR}/junit.xml" \
      --rerun-fails \
      --rerun-fails-max-failures=3 \
      --packages "${TEST_PATH[@]}" \
      --debug \
      -- "${base_cmd[@]:5}"
      
    test_status=$?

else
    "${base_cmd[@]}"
    test_status=$?
fi


# a workaround for https://github.com/kubernetes/kubernetes/issues/63702
# we can detect if tests were terminated prematurely
touch /tmp/ISTIO_TESTS_DONE

# Exit with the status of the test command
exit "$test_status"
