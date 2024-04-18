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

WD=$(dirname "$0")
ROOT=$(dirname "$WD")
WD=$(cd "$WD"; pwd)
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
SKIP_TESTS="${2:-""}"
TEST_SUITE="${1:-"pilot"}"

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

# shellcheck source=common/scripts/kind_provisioner.sh
source "${ROOT}/common/scripts/ocp_setup.sh"

build_images() {
    # Build just the images needed for tests
    targets="docker.pilot docker.proxyv2 docker.install-cni "

    # Integration tests are always running on local architecture (no cross compiling), so find out what that is.
    arch="linux/amd64"
    if [[ "$(uname -m)" == "aarch64" ]]; then
        arch="linux/arm64"
    fi

    # use ubuntu:jammy to test vms by default
    nonDistrolessTargets="docker.app docker.app_sidecar_ubuntu_jammy docker.ext-authz "

    DOCKER_ARCHITECTURES="${arch}"  DOCKER_BUILD_VARIANTS="${VARIANT:-default}" DOCKER_TARGETS="${targets} ${nonDistrolessTargets}" make dockerx.pushx
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
base_cmd="go test -p 1 -v -count=1 -tags=integ -vet=off -timeout 60m ./tests/integration/${TEST_SUITE}/... \
--istio.test.ci \
--istio.test.pullpolicy=IfNotPresent \
--istio.test.work_dir=result \
--istio.test.skipTProxy=true \
--istio.test.skipVM=true \
--istio.test.kube.helm.values=profile=openshift,global.platform=openshift \
--istio.test.istio.enableCNI=true \
--istio.test.hub=\"${HUB}\" \
--istio.test.tag=\"${TAG}\""

# Check if SKIP_TESTS is non-empty and append the -skip flag if it is.
if [ -n "${SKIP_TESTS}" ]; then
  base_cmd+=" -skip '${SKIP_TESTS}'"
fi

# Execute the command.
eval "$base_cmd"
