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
ROOT=$(dirname "$WD")
TIMEOUT=300
export NAMESPACE="${NAMESPACE:-"istio-system"}"
export IMAGE_NAMESPACE="${IMAGE_NAMESPACE:-"istio-images"}"
SAIL_REPO_URL="https://github.com/istio-ecosystem/sail-operator.git"
SAIL_OPERATOR_BRANCH="${SAIL_OPERATOR_BRANCH:-}"  # Will be auto-detected if not set
IBM="${IBM:-"false"}"

# Source lib.sh once at the top to make set_topology_value available
# shellcheck source=prow/lib.sh
if [ -f "${ROOT}/prow/lib.sh" ]; then
  source "${ROOT}/prow/lib.sh"
fi

function setup_internal_registry() {
  # Unified registry setup for single-cluster and multicluster modes
  # For single-cluster: sets up current cluster
  # For multicluster: sets up all clusters in a loop

  echo "Setting up internal registry for all clusters..."

  # Determine which clusters to configure
  local -a target_clusters=()
  local -a target_contexts=()

  if [[ "${TOPOLOGY:-SINGLE_CLUSTER}" != "SINGLE_CLUSTER" ]]; then
    # Multicluster: use all clusters from topology
    target_clusters=("${CLUSTER_NAMES[@]}")
    target_contexts=("${cluster_contexts[@]}")
  else
    # Single cluster: create single-element arrays with current cluster
    target_clusters=("default")
    target_contexts=("$(kubectl config current-context)")
  fi

  # Store all registry URLs for build phase
  export CLUSTER_REGISTRY_URLS=()

  # Loop over all clusters and setup each registry
  for i in "${!target_clusters[@]}"; do
    local cluster_name="${target_clusters[i]}"
    local context="${target_contexts[i]}"

    echo ""
    echo "=== Setting up registry for cluster: ${cluster_name} ==="

    # Check if the registry pods are running
    if oc --context="${context}" get pods -n openshift-image-registry --no-headers 2>/dev/null | grep -v "Running\|Completed" | grep -q .; then
      echo "Warning: Image registry in cluster ${cluster_name} is not fully deployed or running."
    fi

    # Check if default route already exist
    if [ -z "$(oc --context="${context}" get route default-route -n openshift-image-registry -o name 2>/dev/null)" ]; then
      echo "Route default-route does not exist, patching DefaultRoute to true on Image Registry."
      oc --context="${context}" patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

      timeout --foreground -v -s SIGHUP -k ${TIMEOUT} ${TIMEOUT} bash --verbose -c \
        "until oc --context=\"${context}\" get route default-route -n openshift-image-registry &> /dev/null; do sleep 5; done && echo 'The default-route has been created.'"
    fi

    # Get the registry route (external endpoint)
    local registry_url
    registry_url=$(oc --context="${context}" get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
    CLUSTER_REGISTRY_URLS+=("${registry_url}/${IMAGE_NAMESPACE}")
    echo "Registry URL: ${registry_url}/${IMAGE_NAMESPACE}"

    # Create namespace
    oc --context="${context}" create namespace "${NAMESPACE}" 2>/dev/null || true
    oc --context="${context}" create namespace "${IMAGE_NAMESPACE}" 2>/dev/null || true

    # Deploy rolebinding with context flag
    deploy_rolebinding "--context=${context}"

    # Login to registry if CRC
    if [[ ${registry_url} == *".apps-crc.testing"* ]]; then
      echo "Executing Docker login to the internal registry"
      if ! oc --context="${context}" whoami -t | docker login -u "$(oc --context="${context}" whoami)" --password-stdin "${registry_url}"; then
        echo "***** Error: Failed to log in to Docker registry."
        echo "***** Check the error and if is related to 'tls: failed to verify certificate' please add the registry URL as Insecure registry in '/etc/docker/daemon.json'"
        exit 1
      fi
    fi
  done

  export CLUSTER_REGISTRY_URLS

  # Set HUB to first cluster's registry (for build)
  export HUB="${CLUSTER_REGISTRY_URLS[0]}"
  echo ""
  echo "=== Registry setup completed for all clusters ==="
  echo "HUB (build target): ${HUB}"
  echo "Total clusters configured: ${#CLUSTER_REGISTRY_URLS[@]}"
}

function deploy_rolebinding() {
    local context_flag="${1:-}"

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
    namespace: '"$IMAGE_NAMESPACE"'
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
    namespace: '"$IMAGE_NAMESPACE"'
  roleRef:
    apiGroup: rbac.authorization.k8s.io
    kind: ClusterRole
    name: system:image-builder
  subjects:
  - kind: Group
    apiGroup: rbac.authorization.k8s.io
    name: system:unauthenticated
' | oc ${context_flag} apply -f -
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
  # Check if MetalLB is already deployed
  echo "Checking if MetalLB is already deployed..."
  if oc get metallb metallb -n metallb-system && oc get ipaddresspool default -n metallb-system &> /dev/null; then
    echo "MetalLB is already deployed (MetalLB CR and IPAddressPool CR exist), skipping..."
    return 0
  else
    echo "MetalLB CR or IPAddressPool CR is not deployed, deploying..."
  fi

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
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic' | oc apply -f -

  # Check operator Phase is Succeeded
# shellcheck disable=SC2016
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
  
  # IBM specific modifications
  if [ "${IBM}" == "true" ]; then
    # Create L2Advertisement CR
    echo '
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default
  namespace: metallb-system' | oc apply -f -
  fi

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

# Detect and set the sail-operator branch based on current Istio branch
function detect_sail_operator_branch() {
  # Allow explicit override via environment variable
  if [ -n "${SAIL_OPERATOR_BRANCH:-}" ]; then
    echo "Using explicitly set SAIL_OPERATOR_BRANCH: ${SAIL_OPERATOR_BRANCH}"
    return 0
  fi

  # Detect current Istio branch
  local current_branch
  current_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

  # Map Istio branch to sail-operator branch
  if [[ "${current_branch}" == "main" ]] || [[ "${current_branch}" == "master" ]]; then
    SAIL_OPERATOR_BRANCH="main"
  elif [[ "${current_branch}" =~ ^release-[0-9]+\.[0-9]+$ ]]; then
    # Direct mapping: release-X.Y -> release-X.Y
    SAIL_OPERATOR_BRANCH="${current_branch}"
  else
    # Fallback to main for unrecognized patterns (e.g., feature branches)
    echo "Warning: Unrecognized branch pattern '${current_branch}', defaulting to sail-operator main branch"
    SAIL_OPERATOR_BRANCH="main"
  fi

  export SAIL_OPERATOR_BRANCH
  echo "Detected sail-operator branch: ${SAIL_OPERATOR_BRANCH} (from Istio branch: ${current_branch})"
}

function deploy_operator(){
  # Detect appropriate sail-operator branch before cloning
  detect_sail_operator_branch

  # Save and unset env vars so sail-operator's make deploy uses its own defaults
  env_save
  unset HUB
  unset TAG
  unset NAMESPACE

  git clone --depth 1 --branch "${SAIL_OPERATOR_BRANCH}" $SAIL_REPO_URL || { echo "Failed to clone sail-operator repo on branch ${SAIL_OPERATOR_BRANCH}"; exit 1; }
  cd sail-operator

  if [[ "${TOPOLOGY:-SINGLE_CLUSTER}" != "SINGLE_CLUSTER" ]] && [[ ${#cluster_contexts[@]} -gt 0 ]]; then
    IFS=':' read -r -a kubeconfig_paths <<< "${KUBECONFIG}"

    for i in "${!cluster_contexts[@]}"; do
      local ctx="${cluster_contexts[i]}"
      local cluster_kubeconfig="${kubeconfig_paths[i]}"

      echo "Deploying sail-operator on ${ctx} (kubeconfig: ${cluster_kubeconfig})..."
      KUBECONFIG="${cluster_kubeconfig}" make deploy || { echo "sail-operator make deploy failed on ${ctx}"; cleanup_sail_repo ; exit 1; }
      oc --context="${ctx}" -n sail-operator wait --for=condition=Available deployment/sail-operator --timeout=240s || { echo "Failed to start sail-operator on ${ctx}"; exit 1; }
      echo "Sail operator deployed on ${ctx}"
    done
  else
    make deploy || { echo "sail-operator make deploy failed"; cleanup_sail_repo ; exit 1; }
    oc -n sail-operator wait --for=condition=Available deployment/sail-operator --timeout=240s || { echo "Failed to start sail-operator"; exit 1; }
  fi

  # Restore original env vars for subsequent Istio operations
  cleanup_sail_repo
  echo "Sail operator deployed from branch: ${SAIL_OPERATOR_BRANCH}"

}

# Multicluster setup functions

function get_cluster_contexts() {
  # Get matching contexts for all clusters in CLUSTER_NAMES array
  # Returns: Populates cluster_contexts array with matching context for each cluster

  cluster_contexts=()

  # Get all available contexts once
  mapfile -t available_contexts < <(kubectl config get-contexts -o name 2>/dev/null || true)

  # Find matching context for each cluster
  for cluster_name in "${CLUSTER_NAMES[@]}"; do
    local cluster_context=""
    for context in "${available_contexts[@]}"; do
      # Match exact cluster name or context containing cluster name
      if [[ "${context}" == "${cluster_name}" ]] || [[ "${context}" == *"/${cluster_name}/"* ]] || [[ "${context}" == *"-${cluster_name}-"* ]]; then
        cluster_context="${context}"
        break
      fi
    done
    cluster_contexts+=("${cluster_context}")
  done

  export cluster_contexts
}

function normalize_kubeconfig_contexts() {
  # Automatically rename duplicate context/user names to match cluster names from topology
  # This handles the common case where OCP kubeconfigs all have context name "admin" and user "admin"

  echo "Normalizing kubeconfig contexts and users..."

  if [ -z "${KUBECONFIG:-}" ]; then
    echo "Error: KUBECONFIG is not set"
    return 1
  fi

  # Save original KUBECONFIG
  local original_kubeconfig="${KUBECONFIG}"

  # Parse kubeconfig files
  IFS=':' read -r -a kubeconfig_files <<< "${KUBECONFIG}"

  if [ ${#kubeconfig_files[@]} -ne ${#CLUSTER_NAMES[@]} ]; then
    echo "Warning: Number of kubeconfig files (${#kubeconfig_files[@]}) doesn't match number of clusters (${#CLUSTER_NAMES[@]})"
  fi

  # Check if normalization is needed: collect all context names
  local -a file_contexts=()
  local -A seen_contexts=()
  local needs_normalization=0

  for i in "${!kubeconfig_files[@]}"; do
    local kconfig="${kubeconfig_files[i]}"
    if [ ! -f "${kconfig}" ]; then
      file_contexts+=("")
      continue
    fi

    export KUBECONFIG="${kconfig}"
    local ctx
    ctx=$(kubectl config get-contexts -o name 2>/dev/null | head -n1)
    file_contexts+=("${ctx}")

    # Check if this context name is a duplicate OR not in expected names OR in wrong position
    if [ -n "${ctx}" ]; then
      if [[ -n "${seen_contexts[${ctx}]:-}" ]]; then
        # Duplicate context name - needs normalization
        needs_normalization=1
      fi
      seen_contexts["${ctx}"]=1

      # Check if context name matches one of the expected cluster names
      local is_expected=0
      for expected_name in "${CLUSTER_NAMES[@]}"; do
        if [ "${ctx}" == "${expected_name}" ]; then
          is_expected=1
          break
        fi
      done
      if [ ${is_expected} -eq 0 ]; then
        # Context name not in expected list - needs normalization
        needs_normalization=1
      fi

      # Check if context is in the correct position
      if [ $i -lt ${#CLUSTER_NAMES[@]} ]; then
        local expected_for_position="${CLUSTER_NAMES[i]}"
        if [ "${ctx}" != "${expected_for_position}" ]; then
          needs_normalization=1
        fi
      fi
    fi
  done

  # If already normalized correctly, just fix current-context fields and exit
  if [ ${needs_normalization} -eq 0 ]; then
    echo "All contexts already normalized correctly, skipping..."
    for i in "${!kubeconfig_files[@]}"; do
      local kconfig="${kubeconfig_files[i]}"
      local ctx="${file_contexts[i]}"
      if [ -f "${kconfig}" ] && [ -n "${ctx}" ]; then
        export KUBECONFIG="${kconfig}"
        sed -i "s/^current-context: .*/current-context: ${ctx}/" "${kconfig}"
      fi
    done
    export KUBECONFIG="${original_kubeconfig}"
    return 0
  fi

  # Perform normalization - rename contexts by position
  echo "Performing context normalization..."
  for i in "${!kubeconfig_files[@]}"; do
    if [ $i -ge ${#CLUSTER_NAMES[@]} ]; then
      break
    fi

    local kconfig="${kubeconfig_files[i]}"
    local current_context="${file_contexts[i]}"
    local target_name="${CLUSTER_NAMES[i]}"

    if [ ! -f "${kconfig}" ] || [ -z "${current_context}" ]; then
      continue
    fi

    export KUBECONFIG="${kconfig}"

    # Get the user associated with this context
    local current_user
    current_user=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${current_context}')].context.user}" 2>/dev/null || echo "")

    # Rename context if needed
    if [ "${current_context}" != "${target_name}" ]; then
      echo "  Renaming context '${current_context}' -> '${target_name}' in ${kconfig}"
      kubectl config rename-context "${current_context}" "${target_name}" 2>/dev/null || {
        echo "  Warning: Failed to rename context in ${kconfig}"
      }
    fi

    # Rename user if needed
    if [ -n "${current_user}" ] && [ "${current_user}" != "${target_name}" ]; then
      echo "  Renaming user '${current_user}' -> '${target_name}' in ${kconfig}"
      sed -i "s/name: ${current_user}$/name: ${target_name}/g" "${kconfig}"
      sed -i "s/user: ${current_user}$/user: ${target_name}/g" "${kconfig}"
    fi

    # Fix current-context field
    sed -i "s/^current-context: .*/current-context: ${target_name}/" "${kconfig}"
  done

  # Restore original KUBECONFIG with all files
  export KUBECONFIG="${original_kubeconfig}"

  echo "Context and user normalization completed"
}

function load_cluster_topology() {
  local topology_file="$1"

  if [ ! -f "${topology_file}" ]; then
    echo "Error: Topology file ${topology_file} not found"
    exit 1
  fi

  echo "Loading cluster topology from ${topology_file}"
  # Extract cluster names and networks from topology JSON
  mapfile -t CLUSTER_NAMES < <(jq -r '.[] | .clusterName' "${topology_file}")
  mapfile -t CLUSTER_NETWORKS < <(jq -r '.[] | .network' "${topology_file}")

  export CLUSTER_NAMES
  export CLUSTER_NETWORKS
  export NUM_CLUSTERS="${#CLUSTER_NAMES[@]}"

  echo "Loaded ${NUM_CLUSTERS} clusters from topology:"
  for i in "${!CLUSTER_NAMES[@]}"; do
    echo "  - ${CLUSTER_NAMES[i]} (network: ${CLUSTER_NETWORKS[i]})"
  done

  # Get cluster contexts once for all clusters
  # Note: Context normalization should have been done before calling this function
  get_cluster_contexts

  echo "Resolved cluster contexts:"
  for i in "${!CLUSTER_NAMES[@]}"; do
    echo "  - ${CLUSTER_NAMES[i]} -> ${cluster_contexts[i]}"
  done
}

function validate_ocp_multicluster_kubeconfigs() {
  echo "Validating OCP multicluster kubeconfigs..."

  # Check if KUBECONFIG environment variable is set
  if [ -z "${KUBECONFIG:-}" ]; then
    echo "Error: KUBECONFIG environment variable is not set"
    echo "Expected format: KUBECONFIG=/path/to/primary.kubeconfig:/path/to/remote.kubeconfig"
    exit 1
  fi

  echo "KUBECONFIG: ${KUBECONFIG}"

  # Validate each cluster in topology has a matching context
  local missing_contexts=()
  for i in "${!CLUSTER_NAMES[@]}"; do
    local cluster_name="${CLUSTER_NAMES[i]}"
    local context="${cluster_contexts[i]}"

    if [ -z "${context}" ]; then
      missing_contexts+=("${cluster_name}")
    else
      echo "Found context for cluster ${cluster_name}: ${context}"
    fi
  done

  if [ ${#missing_contexts[@]} -gt 0 ]; then
    echo "Error: Missing contexts for the following clusters:"
    printf '  - %s\n' "${missing_contexts[@]}"
    echo ""
    echo "Available contexts:"
    mapfile -t available_contexts < <(kubectl config get-contexts -o name 2>/dev/null || true)
    printf '  - %s\n' "${available_contexts[@]}"
    exit 1
  fi

  # Validate cluster access by running oc cluster-info for each cluster
  echo "Validating cluster access..."
  for i in "${!CLUSTER_NAMES[@]}"; do
    local cluster_name="${CLUSTER_NAMES[i]}"
    local cluster_context="${cluster_contexts[i]}"

    if ! oc --context="${cluster_context}" cluster-info &> /dev/null; then
      echo "Error: Cannot access cluster ${cluster_name} using context ${cluster_context}"
      exit 1
    fi

    echo "Successfully validated access to cluster ${cluster_name}"
  done

  echo "All multicluster kubeconfigs validated successfully"
}

function setup_ocp_multicluster_topology() {
  echo "Setting up OCP multicluster topology configuration..."

  local topology_file="$1"
  local runtime_topology_file="${ARTIFACTS_DIR}/topology-config.json"

  # Read the original topology JSON
  local topology_json
  topology_json=$(cat "${topology_file}")

  # Extract kubeconfig paths from KUBECONFIG environment variable
  IFS=':' read -r -a kubeconfig_paths <<< "${KUBECONFIG}"

  # For each cluster, inject the kubeconfig path
  for i in "${!CLUSTER_NAMES[@]}"; do
    local cluster_name="${CLUSTER_NAMES[i]}"
    local cluster_context="${cluster_contexts[i]}"

    # Find the kubeconfig file that contains this context
    local kubeconfig_path=""
    for kconfig in "${kubeconfig_paths[@]}"; do
      if kubectl --kubeconfig="${kconfig}" config get-contexts "${cluster_context}" &>/dev/null; then
        kubeconfig_path="${kconfig}"
        break
      fi
    done

    if [ -z "${kubeconfig_path}" ]; then
      echo "Warning: Could not find kubeconfig file for cluster ${cluster_name}, using merged KUBECONFIG"
      # Use the first kubeconfig in the list as fallback
      kubeconfig_path="${kubeconfig_paths[0]}"
    fi

    echo "Cluster ${cluster_name}: kubeconfig=${kubeconfig_path}"

    # Inject kubeconfig path into topology JSON
    topology_json=$(set_topology_value "${topology_json}" "${cluster_name}" "meta.kubeconfig" "${kubeconfig_path}")
  done

  # Write the runtime topology configuration
  echo "${topology_json}" > "${runtime_topology_file}"

  echo "Runtime topology configuration written to ${runtime_topology_file}"
  echo "Topology contents:"
  jq '.' "${runtime_topology_file}"

  export INTEGRATION_TEST_TOPOLOGY_FILE="${runtime_topology_file}"
}

function generate_dynamic_topology() {
  local num_clusters="$1"
  local topology_type="${2:-MULTICLUSTER}"
  local output_file="${ARTIFACTS_DIR}/dynamic-topology.json"

  echo "Generating dynamic topology for ${num_clusters} clusters (type: ${topology_type})"

  # Get available contexts from KUBECONFIG
  mapfile -t available_contexts < <(kubectl config get-contexts -o name 2>/dev/null || true)

  if [[ ${#available_contexts[@]} -lt ${num_clusters} ]]; then
    echo "Error: Requested ${num_clusters} clusters, but only ${#available_contexts[@]} contexts available in KUBECONFIG"
    exit 1
  fi

  # Well-known cluster names for Istio test framework
  local -a cluster_names=("primary" "remote" "cross-network-primary")
  local -a networks=("network-1" "network-1" "network-2")

  # For ambient multicluster, use cross-network configuration
  if [[ "${topology_type}" == "AMBIENT_MULTICLUSTER" ]]; then
    networks=("network-1" "network-2" "network-3")
  fi

  # Build topology JSON
  local topology_json="["

  for i in $(seq 0 $((num_clusters - 1))); do
    local cluster_name="${cluster_names[i]}"
    local network="${networks[i]}"

    # Add cluster entry
    if [[ $i -gt 0 ]]; then
      topology_json+=","
    fi

    topology_json+='
  {
    "kind": "Kubernetes",
    "clusterName": "'${cluster_name}'",
    "network": "'${network}'"'

    # Add primaryClusterName for remote clusters
    if [[ "${cluster_name}" == "remote" ]]; then
      topology_json+=',
    "primaryClusterName": "primary"'
    fi

    topology_json+='
  }'
  done

  topology_json+='
]'

  # Write topology file
  echo "${topology_json}" > "${output_file}"

  echo "Dynamic topology generated at ${output_file}:"
  jq '.' "${output_file}"

  echo "${output_file}"
}


