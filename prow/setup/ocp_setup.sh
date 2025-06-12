#!/bin/bash

# WARNING: DO NOT EDIT, THIS FILE IS PROBABLY A COPY
#
# The original version of this file is located in the https://github.com/istio/common-files repo.
# If you're looking at this file in a different repo and want to make a change, please go to the
# common-files repo, make the change there and check it in. Then come back to this repo and run
# "make update-common".

# Copyright Istio Authors
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

set -e
set -x

# The purpose of this file is to unify ocp setup in both istio/istio and istio-ecosystem/sail-operator.
# repos to avoid code duplication. This is needed to setup the OCP environment for the tests.

WD=$(dirname "$0")
WD=$(cd "$WD"; pwd)
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
SAIL_REPO_URL="https://github.com/istio-ecosystem/sail-operator.git"

function setup_internal_registry() {
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

  # Create namespace from where the image are going to be pushed
  # This is needed because in the internal registry the images are stored in the namespace.
  # If the namespace already exist, it will not fail
  oc create namespace "${NAMESPACE}" || true

  deploy_rolebinding

  # Login to the internal registry when running on CRC (Only for local development)
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

function deploy_rolebinding() {
    # Adding roles to avoid the need to be authenticated to push images to the internal registry 
    # and pull them later in the any namespace
      echo '
kind: List
apiVersion: v1
items:
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: image-puller
    namespace: '"$NAMESPACE"'
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:image-puller
  subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: system:unauthenticated
  - kind: Group
    name: system:serviceaccounts
    apiGroup: rbac.authorization.k8s.io
- apiVersion: rbac.authorization.k8s.io/v1
  kind: RoleBinding
  metadata:
    name: image-pusher
    namespace: '"$NAMESPACE"'
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:image-builder
  subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: system:unauthenticated
' | oc apply -f -
}

# Set gcr.io as mirror to docker.io/istio to be able to get images in downstream tests.
function addGcrMirror(){
  oc apply -f - <<__EOF__
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: docker-images-from-gcr
spec:
  imageDigestMirrors:
  - mirrors:
    - mirror.gcr.io
    source: docker.io
    mirrorSourcePolicy: NeverContactSource
---
apiVersion: config.openshift.io/v1
kind: ImageTagMirrorSet
metadata:
  name: docker-images-from-gcr
spec:
  imageTagMirrors:
  - mirrors:
    - mirror.gcr.io
    source: docker.io
    mirrorSourcePolicy: NeverContactSource
__EOF__
}

# Deploy MetalLB in the OCP cluster and configure IP address pool
function deployMetalLB() {
  # Create the metallb-system namespace
  echo '
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system' | oc apply -f -

  # Create Subscription for MetalLB
  echo '
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator-sub
  namespace: metallb-system
spec:
  channel: stable
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace' | oc apply -f -

  # Check operator Phase is Succeeded
timeout --foreground -v -s SIGHUP -k ${TIMEOUT} ${TIMEOUT} bash -c 'until [ "$(oc get csv -n metallb-system | awk "/metallb-operator/ {print \$NF}")" == "Succeeded" ]; do sleep 5; done && echo "The MetalLB operator has been installed."'

  # Create MetalLB CR
  echo '
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system' | oc apply -f -

  # Check MetalLB controller is running
timeout --foreground -v -s SIGHUP -k ${TIMEOUT} ${TIMEOUT} bash -c 'until oc get pods -n metallb-system --no-headers | grep controller | grep "Running"; do sleep 5; done && echo "The MetalLB controller is running."'

  # Get Nodes Internal IP by using: kubectl get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}'
  NODE_IPS=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' | tr ' ' ',')

  # Split The IPs by , to create the IP address pool
  IFS=',' read -r -a array <<< "${NODE_IPS}"

  # Iterate over the Create IPS to create address pool
  IP_POOL_YAML='
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:'

  # Iterate over the IPs to create address pool entries
  for ip in "${array[@]}"; do
    IP_POOL_YAML+=$'\n  - '"${ip}-${ip}"
  done
  echo "IP Pool YAML: ${IP_POOL_YAML}"

  # Apply the IP address pool
  echo "${IP_POOL_YAML}" | oc apply -f -

  # Check the IP address pool is created
  timeout --foreground -v -s SIGHUP -k ${TIMEOUT} ${TIMEOUT} bash -c 'until oc get IPAddressPool default -n metallb-system; do sleep 5; done && echo "The IP address pool has been created."'

  echo "MetalLB has been deployed and configured with the IP address pool."
}

#need to change env variables since make deploy of sail-operator uses them
function env_save(){
  INICIAL_NAMESPACE="$NAMESPACE"
  INICIAL_HUB="$HUB"
  INITIAL_TAG="$TAG"
}
function cleanup_sail_repo() {
    echo "Cleaning up..."
    cd .. 2>/dev/null || true
    rm -rf sail-operator
    export NAMESPACE="$INICIAL_NAMESPACE"
    export HUB="$INICIAL_HUB"
    export TAG="$INITIAL_TAG"
}

function deploy_operator(){
  env_save
  unset HUB
  unset TAG
  unset NAMESPACE
  git clone --depth 1 --branch main $SAIL_REPO_URL || { echo "Failed to clone sail-operator repo"; exit 1; }
  cd sail-operator
  make deploy || { echo "sail-operator make deploy failed"; cleanup_sail_repo ; exit 1; }
  oc -n sail-operator wait --for=condition=Available deployment/sail-operator --timeout=240s || { echo "Failed to start sail-operator"; exit 1; }
  cleanup_sail_repo
  echo "Sail operator deployed"

}