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
# Usage: ./integ-suite-ocp.sh TEST_SUITE SKIP_TESTS, example: /prow/integ-suite-ocp.sh telemetry "TestClientTracing|TestServerTracing"
# TEST_SUITE: The test suite to run. Default is "pilot". Available options are "pilot", "security", "telemetry", "helm".
# TODO: Use the same arguments as integ-suite.kind.sh uses

WD=$(dirname "$0")
ROOT=$(dirname "$WD")
WD=$(cd "$WD"; pwd)
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
SKIP_TESTS="${2:-""}"
TEST_SUITE="${1:-"pilot"}"
SKIP_SUITE="${3:-""}"
SKIP_SETUP="${SKIP_SETUP:-"false"}"
INSTALL_METALLB="${INSTALL_METALLB:-"false"}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-"sail-operator"}"
CONTROL_PLANE_SOURCE="${CONTROL_PLANE_SOURCE:-"istio"}"
INSTALL_SAIL_OPERATOR="${INSTALL_SAIL_OPERATOR:-"false"}"
TRUSTED_ZTUNNEL_NAMESPACE="${TRUSTED_ZTUNNEL_NAMESPACE:-"istio-system"}"
AMBIENT="${AMBIENT:="false"}"
TEST_HUB="${TEST_HUB:="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}"}"
DEPLOY_GATEWAY_API="false"

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

# shellcheck source=common/scripts/kind_provisioner.sh
source "${ROOT}/prow/setup/ocp_setup.sh"

build_images() {
    # Build just the images needed for tests
    targets="docker.pilot docker.proxyv2 docker.install-cni "

    # Integration tests are always running on local architecture (no cross compiling), so find out what that is.
    arch="linux/amd64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="linux/arm64"
    fi

    # use ubuntu:noble to test vms by default
    nonDistrolessTargets="docker.app docker.app_sidecar_ubuntu_noble docker.ext-authz docker.ztunnel "

    if [[ "${VARIANT:-default}" == "distroless" ]]; then
        echo "Building distroless images"
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="distroless" DOCKER_TARGETS="${targets}" make dockerx.pushx
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="default" DOCKER_TARGETS="${nonDistrolessTargets}" make dockerx.pushx
    else
        echo "Building default images"
        DOCKER_ARCHITECTURES="${arch}"  DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" make dockerx.pushx
    fi
}

# Define the artifacts directory
ARTIFACTS_DIR="${ARTIFACT_DIR:-"${WD}/artifacts"}"
JUNIT_REPORT_DIR="${ARTIFACTS_DIR}/junit"

# Install MetalLB if the flag is set
if [ "${INSTALL_METALLB}" == "true" ]; then
    echo "Installing MetalLB"
    deployMetalLB

# Run the setup only if MetalLB is not being installed and setup is not skipped
elif [ "${INSTALL_METALLB}" != "true" ] && [ "${SKIP_SETUP}" != "true" ]; then
    echo "Running full setup..."

    # Ensure artifacts directory exists
    mkdir -p "${JUNIT_REPORT_DIR}"

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

helm_values="global.platform=openshift"

# Gateway Conformance Test related modifications
if [ "${TEST_SUITE}" == "pilot" ]; then
    # Until OCP 4.19 default CRDs has https://github.com/kubernetes-sigs/gateway-api/pull/3389 we need following patch
    git apply --verbose --reject --whitespace=fix --ignore-space-change ./prow/config/sail-operator/istio-gw-api-coredns-fix.patch
    # This flag we need to run the conformance test even if the CRDs are not matching with the desired ones in go.mod
    base_cmd+=("--istio.test.GatewayConformanceAllowCRDsMismatch=true")
    # Stops flaky runs in public clouds
    base_cmd+=("--istio.test.gatewayConformance.maxTimeToConsistency=180s")
fi

# If ambient mode executed, add "ambient" profile and args
if [ "${AMBIENT}" == "true" ]; then
    base_cmd+=("--istio.test.ambient")
    helm_values+=",pilot.trustedZtunnelNamespace=${TRUSTED_ZTUNNEL_NAMESPACE}"

    # Set local gateway mode for Ambient execution
    oc patch networks.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
    routing_via_host=$(oc get networks.operator.openshift.io cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig.routingViaHost}')
    if [ "${routing_via_host}" != "true" ]; then
        echo "Unable to set local gateway mode for Ambient execution"
        exit 1
    fi
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

    base_cmd+=("-timeout=120m")

    # Add sail operator setup script
    SAIL_SETUP_SCRIPT="${WD}/setup/sail-operator-setup.sh"
    base_cmd+=("--istio.test.kube.deploy=false")
    base_cmd+=("--istio.test.kube.controlPlaneInstaller=${SAIL_SETUP_SCRIPT}")
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
      --rerun-fails-max-failures=30 \
      --packages "${TEST_PATH[@]}" \
      --debug \
      -- "${base_cmd[@]:5}"
      
    test_status=$?

else
    "${base_cmd[@]}"
    test_status=$?
fi

# Exit with the status of the test command
exit "$test_status"
