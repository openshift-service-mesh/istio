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
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
SKIP_TESTS="${2:-""}"
TEST_SUITE="${1:-"pilot"}"
# TEST_OUTPUT_FORMAT set the output format for the test result. Currently only supports: not set and junit
# If you are executing locally you will need to install before the go-junit-report package
TEST_OUTPUT_FORMAT="${TEST_OUTPUT_FORMAT:-"junit"}"

# Check if artifact dir exist and if not create it in the current directory
ARTIFACTS_DIR="${ARTIFACT_DIR:-"${WD}/artifacts"}"
mkdir -p "${ARTIFACTS_DIR}/junit"
JUNIT_REPORT_DIR="${ARTIFACTS_DIR}/junit"

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
    nonDistrolessTargets="docker.app docker.app_sidecar_ubuntu_noble docker.ext-authz "

    if [[ "${TEST_SUITE}" == "helm" ]]; then
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="distroless" DOCKER_TARGETS="${targets}" make dockerx.pushx
        DOCKER_ARCHITECTURES="${arch}" DOCKER_BUILD_VARIANTS="default" DOCKER_TARGETS="${nonDistrolessTargets}" make dockerx.pushx
    else
        DOCKER_ARCHITECTURES="${arch}"  DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" make dockerx.pushx
    fi
}

# Setup the internal registry for ocp cluster
setup_internal_registry

# Build and push the images to the internal registry
build_images

# Run the integration tests
echo "Running integration tests"

# Set the HUB to the internal registry svc URL to avoid the need to authenticate to pull images
HUB="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}"

# Build the base command and store it in a variable.
# TODO: execute the test by running make target. Do we need first to add a skip flag to the make target to be able to skip failing test on OCP
# All the flags are needed to run the integration tests on OCP
# Initialize base_cmd
base_cmd=""

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

# Base command setup
base_cmd="go test -p 1 -v -count=1 -tags=integ -vet=off -timeout 60m ./tests/integration/${TEST_SUITE}/... \
--istio.test.ci \
--istio.test.pullpolicy=IfNotPresent \
--istio.test.work_dir=${ARTIFACTS_DIR} \
--istio.test.skipTProxy=true \
--istio.test.skipVM=true \
--istio.test.kube.helm.values='profile=openshift,global.platform=openshift' \
--istio.test.istio.enableCNI=true \
--istio.test.hub=\"${HUB}\" \
--istio.test.tag=\"${TAG}\" \
--istio.test.openshift"

# Append skip tests flag if SKIP_TESTS is set
if [ -n "${SKIP_TESTS}" ]; then
    base_cmd+=" -skip '${SKIP_TESTS}'"
fi

# Add junit output for when the TEST_OUTPUT_FORMAT is set to junit
if [ "${TEST_OUTPUT_FORMAT}" == "junit" ]; then
    echo "A junit report file will be generated"
    setup_junit_report
    base_cmd+=" 2>&1 | tee >(${JUNIT_REPORT} > ${ARTIFACTS_DIR}/junit/junit.xml)"
fi

# Execute the command.
eval "$base_cmd"
