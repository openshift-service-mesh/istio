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
# Usage: ./integ-suite-ocp.sh TEST_SUITE GO_TEST_FLAGS
# TEST_SUITE: The test suite to run. Default is "pilot". Available options are "pilot", "security", "telemetry", "helm".

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
ROOT=$(dirname "$WD")
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export TAG="${TAG:-"istio-testing"}"
GO_TEST_FLAGS="${2:-""}"
TEST_SUITE="${1:-"pilot"}"

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

get_internal_registry() {
  # Validate that the internal registry is running in the OCP Cluster, configure the variable to be used in the make target. 
  # If there is no internal registry, the test can't be executed targeting to the internal registry

  # Check if the registry pods are running
  oc get pods -n openshift-image-registry --no-headers | grep -v "Running\|Completed" && echo "It looks like the OCP image registry is not deployed or Running. This tests scenario requires it. Aborting." && exit 1

  # Check if default route already exist
  if [ -z "$(oc get route default-route -n openshift-image-registry -o name)" ]; then
    echo "Route default-route does not exist, patching DefaultRoute to true on Image Registry."
    oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge
  
    timeout --foreground -v -s SIGHUP -k ${TIMEOUT} ${TIMEOUT} bash --verbose -c \
      "until oc get route default-route -n openshift-image-registry &> /dev/null; do sleep 5; done && echo 'The 'default-route' has been created.'"
  fi

  # Get the registry route
  URL=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
  # Hub will be equal to the route url/project-name(NameSpace) 
  export HUB="${URL}/${NAMESPACE}"
  echo "Internal registry URL: ${HUB}"

  # Create namespace where operator will be located
  # This is needed because the roles are created in the namespace where the operator is deployed
  oc create namespace "${NAMESPACE}" || true

  # Adding roles to avoid the need to be authenticated to push images to the internal registry
  # Using envsubst to replace the variable NAMESPACE in the yaml file
  envsubst < "${WD}/config/role-bindings.yaml" | oc apply -f -
  envsubst < "${WD}/config/role-bindings-kube-system.yaml" | oc apply -f -

  # Login to the internal registry when running on CRC
  # Take into count that you will need to add before the registry URL as Insecure registry in "/etc/docker/daemon.json"
  if [[ ${URL} == *".apps-crc.testing"* ]]; then
    echo "Executing Docker login to the internal registry"
    if ! oc whoami -t | docker login -u "$(oc whoami)" --password-stdin "${URL}"; then
      echo "***** Error: Failed to log in to Docker registry."
      echo "***** Check the error and if is related to 'tls: failed to verify certificate' please add the registry URL as Insecure registry in '/etc/docker/daemon.json'"
      exit 1
    fi
  fi
}

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
get_internal_registry

# Build and push the images to the internal registry
build_images

# Run the integration tests
echo "Running integration tests"
HUB="image-registry.openshift-image-registry.svc:5000/${NAMESPACE}"

go test -p 1 -v -count=1 -tags=integ -vet=off -timeout 90m ./tests/integration/${TEST_SUITE}/... \
--istio.test.ci \
--istio.test.pullpolicy=IfNotPresent \
--istio.test.work_dir=result \
--istio.test.skipTProxy=true \
--istio.test.skipVM=true \
--istio.test.kube.helm.values=global.platform=openshift \
--istio.test.istio.enableCNI=true \
--istio.test.hub="${HUB}" \
--istio.test.tag="${TAG}" \
-skip 'TestProxyTracingOpenCensusMeshConfig|TestProxyTracingOpenTelemetryProvider|TestClientTracing|TestServerTracing'