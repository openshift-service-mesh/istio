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

# The integration test runtime is calling this script two times if istio.test.kube.controlPlaneInstaller parameter set. One call is with 
# install and another is with cleanup. On install script is used to convert istio in-cluster operator config to sail operator config and install istiod, istio-cni and gateways.
# On cleanup  istiod, istio-cni, istio-ingressgateway and istio-engressgateway are cleaned
# The output log of this script is printed under working directory set by: --istio.test.work_dir/sail-operator-setup.log
# Upstream WoW to call this script is documented in here: https://github.com/openshift-service-mesh/istio/tree/master/tests/integration#running-tests-on-custom-deployment

LOG_FILE="$2/sail-operator-setup.log"
# Redirect stdout and stderr to the log file
exec > >(awk '{print strftime("[%Y-%m-%d %H:%M:%S]"), $0}' | tee -a "$LOG_FILE") 2>&1

# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x
# fail if any command in the pipeline fails
set -o pipefail
# Show logs on error
trap 'echo "❌ Script failed. Dumping log:"; echo "--------------------------------"; cat "$LOG_FILE"; echo "--------------------------------"; exit 1' ERR

SKIP_CLEANUP="${SKIP_CLEANUP:-"false"}"


function usage() {
    echo "Usage: $0 <install|cleanup> <input_yaml>"
    echo "Example: $0 install /path/to/iop.yaml"
    exit 1
}

if [[ $# -lt 2 ]]; then
    echo "Error: Missing required arguments."
    usage
fi

if ! command -v yq &>/dev/null; then
    echo "Error: 'yq' is not installed. Please install it before running the script."
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "Helm is not installed. Please install Helm before proceeding."
    exit 1
fi

WD=$(dirname "$0")
PROW="$(dirname "$WD")"
ROOT="$(dirname "$PROW")"

WORKDIR="$2"
# iop.yaml is the static file name for istiod config created by upstream integration test runtime
IOP_FILE="$2"/iop.yaml
SAIL_IOP_FILE="$(basename "${IOP_FILE%.yaml}")-sail.yaml"

# Control Istio Ambient mode deploy
AMBIENT="${AMBIENT:="false"}"

CONVERTER_BRANCH="${CONVERTER_BRANCH:-main}"

# get istio version from versions.yaml
VERSION_FILE="https://raw.githubusercontent.com/istio-ecosystem/sail-operator/$CONVERTER_BRANCH/pkg/istioversion/versions.yaml"
if [ -n "${ISTIO_VERSION:-}" ]; then
  echo "Using provided ISTIO_VERSION: $ISTIO_VERSION"
else
  if [ "$CONVERTER_BRANCH" = "main" ]; then
    # If CONVERTER_BRANCH is main, change it to master and get the ref field
    ISTIO_VERSION="$(curl -s "$VERSION_FILE" | \
      grep -A 1 'name: master' | \
      grep 'ref:' | \
      sed -E 's/.*ref: (.*)/\1/' | \
      head -n1)"
  else
    # Handle version stripping for CONVERTER_BRANCH like "release-1.28" -> "1.28"
    if [[ "$CONVERTER_BRANCH" =~ ^release- ]]; then
      # Strip "release-" prefix to get version (e.g., release-1.28 -> 1.28)
      SEARCH_VERSION="${CONVERTER_BRANCH#release-}"
    fi

    # Look for the version with -latest suffix
    ISTIO_VERSION="$(curl -s "$VERSION_FILE" | \
      grep -E "name: v${SEARCH_VERSION}-latest" | \
      sed -E "s/.*(v${SEARCH_VERSION}-latest).*/\1/" | \
      head -n1)"
  fi
  echo "Using fetched ISTIO_VERSION: $ISTIO_VERSION"
fi

NAMESPACE="${NAMESPACE:-istio-system}"
ISTIOCNI_NAMESPACE="${ISTIOCNI_NAMESPACE:-istio-cni}"
ZTUNNEL_NAMESPACE="${ZTUNNEL_NAMESPACE:-ztunnel}"

ISTIOCNI="${PROW}/config/sail-operator/istio-cni.yaml"
ZTUNNEL="${PROW}/config/sail-operator/ztunnel.yaml"
INGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/ingress-gateway-values.yaml"
EGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/egress-gateway-values.yaml"
EASTWEST_GATEWAY_VALUES="${PROW}/config/sail-operator/eastwest-gateway-values.yaml"
EASTWEST_GATEWAY_AMBIENT_MANIFEST="${PROW}/config/sail-operator/eastwest-gateway-ambient.yaml"

CONVERTER_ADDRESS="https://raw.githubusercontent.com/istio-ecosystem/sail-operator/$CONVERTER_BRANCH/tools/configuration-converter.sh"
CONVERTER_SCRIPT=$(basename "$CONVERTER_ADDRESS")

function download_execute_converter(){
  cd "${PROW}"
  curl -fsSL "$CONVERTER_ADDRESS" -o "$CONVERTER_SCRIPT" || { echo "Failed to download converter script"; exit 1; }
  chmod +x "$CONVERTER_SCRIPT"
  bash "$CONVERTER_SCRIPT" "$IOP_FILE" -v "$ISTIO_VERSION" -n "$NAMESPACE" || { echo "Failed to execute converter script"; exit 1; }
  rm "$CONVERTER_SCRIPT"
}

function install_istio_cni(){
  oc create namespace "${ISTIOCNI_NAMESPACE}" || true
  TMP_ISTIOCNI=$WORKDIR/istio-cni.yaml
  cp "$ISTIOCNI" "$TMP_ISTIOCNI"
  yq -i ".spec.namespace=\"$ISTIOCNI_NAMESPACE\"" "$TMP_ISTIOCNI"
  yq -i ".spec.version=\"$ISTIO_VERSION\"" "$TMP_ISTIOCNI"
  if [ "$AMBIENT" == "true" ]; then
    yq -i '.spec.profile="ambient"' "$TMP_ISTIOCNI"
  fi
  patch_istiocni_config
  oc apply -f "$TMP_ISTIOCNI"
  echo "istioCNI created."
}

function install_ztunnel() {
  local cluster_idx="${1:-}"
  oc create namespace "${ZTUNNEL_NAMESPACE}" || true
  TMP_ZTUNNEL=$WORKDIR/ztunnel.yaml
  cp "$ZTUNNEL" "$TMP_ZTUNNEL"
  yq -i ".spec.namespace=\"$ZTUNNEL_NAMESPACE\"" "$TMP_ZTUNNEL"
  yq -i ".spec.version=\"$ISTIO_VERSION\"" "$TMP_ZTUNNEL"
  patch_ztunnel_config

  if [ -n "$cluster_idx" ]; then
    local cluster_name="${ALL_CLUSTER_NAMES[$cluster_idx]}"
    local network="${ALL_CLUSTER_NETWORKS[$cluster_idx]}"
    yq -i ".spec.values.ztunnel.multiCluster.clusterName = \"$cluster_name\"" "$TMP_ZTUNNEL"
    yq -i ".spec.values.ztunnel.network = \"$network\"" "$TMP_ZTUNNEL"
    echo "Set ztunnel cluster identity: clusterName=$cluster_name, network=$network"
  fi

  oc apply -f "$TMP_ZTUNNEL"
  echo "ZTunnel created."
}

function install_istio(){
  # overwrite sailoperator version before applying it
  oc create namespace "${NAMESPACE}" || true
  if [ "${SAIL_API_VERSION:-}" != "" ]; then
    yq -i eval ".apiVersion = \"sailoperator.io/$SAIL_API_VERSION\"" "$WORKDIR/$SAIL_IOP_FILE"
  fi
  patch_config
  oc apply -f "$WORKDIR/$SAIL_IOP_FILE" || { echo "Failed to install istio"; kubectl get istio default -o yaml;}
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istiod --timeout=240s || { sleep 60; }
  echo "istiod created."
}

function patch_config() {
  # adds some control plane values that are mandatory and not available in iop.yaml
  if [[ "$WORKDIR" == *"telemetry-api"* ]]; then
    # The patch for the telemetry api tests is added because PR
    # https://github.com/istio-ecosystem/sail-operator/pull/1186
    # adds "accessLogFile" globally and telemetry api needs it to be empty.
    yq eval '
      .spec.values.meshConfig.accessLogFile = ""
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured telemetry api."

  elif [[ "$WORKDIR" == *"telemetry-tracing-zipkin"* ]]; then
  # Workaround until https://github.com/istio/istio/pull/55408 is merged
    yq eval '
      .spec.values.meshConfig.enableTracing = true |
      .spec.values.pilot.traceSampling = 100.0 |
      .spec.values.global.proxy.tracer = "zipkin"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured tracing for Zipkin."

  elif [[ "$WORKDIR" == *"telemetry-tracing-otelcollector"* ]]; then
  # Workaround until https://issues.redhat.com/browse/OSSM-10480 fixed
    yq eval 'del(.spec.values.pilot.envVarFrom)' -i "$WORKDIR/$SAIL_IOP_FILE"
    otel_cred="$(kubectl -n "$NAMESPACE" get secret otel-credentials -o jsonpath='{.data.bearer-token}' | base64 -d)"
    CRED="$otel_cred" yq eval '
      .spec.values.pilot.env.OTEL_GRPC_AUTHORIZATION = env(CRED) |
      .spec.values.pilot.env.OTEL_GRPC_AUTHORIZATION style="double"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured tracing for OtelCollector."

  elif [[ "$WORKDIR" == *"telemetry-policy-dynamicdns"* ]]; then
    yq eval '
      .spec.values.meshConfig.enablePrometheusMerge = true |
      .spec.values.meshConfig.outboundTrafficPolicy.mode = "ALLOW_ANY_DYNAMIC_DNS" |
      .spec.values.meshConfig.outboundTrafficPolicy.tls.mode = "SIMPLE" |
      .spec.values.meshConfig.outboundTrafficPolicy.tls.insecureSkipVerify = true
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured telemetry policy for DynamicDNS"

  elif [[ "$WORKDIR" == *"pilot-"* ]]; then
    # Fix for TestTraffic/dns/a/ tests
    yq eval '
      .spec.values.meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE = "true"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Enabled DNS capture for Istio proxy."
  fi

  # Set Ambient config if set
  if [[ "$AMBIENT" == "true" ]]; then
    yq eval '.spec.profile = "ambient"' -i "$WORKDIR/$SAIL_IOP_FILE"
    yq eval ".spec.values.pilot.trustedZtunnelNamespace = \"$ZTUNNEL_NAMESPACE\"" -i "$WORKDIR/$SAIL_IOP_FILE"

    # Add discoverySelectors to match Helm behavior
    yq eval '.spec.values.meshConfig.discoverySelectors = [{"matchExpressions": [{"key": "istio.io/test-exclude-namespace", "operator": "DoesNotExist"}]}]' -i "$WORKDIR/$SAIL_IOP_FILE"

    # Add configurations for ServiceEntry/DNS resolution
    yq eval '.spec.values.meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE = "true"' -i "$WORKDIR/$SAIL_IOP_FILE"

    if [[ "${TOPOLOGY}" != "SINGLE_CLUSTER" ]]; then
      yq eval '.spec.values.pilot.env.AMBIENT_ENABLE_MULTI_NETWORK = "true" |
               .spec.values.pilot.env.AMBIENT_ENABLE_MULTI_NETWORK_INGRESS = "true" |
               .spec.values.pilot.env.AMBIENT_ENABLE_BAGGAGE = "true"
      ' -i "$WORKDIR/$SAIL_IOP_FILE"

      echo "Configured Ambient mode for multi-network Istio."
    fi

    echo "Configured Ambient mode for Istio."
  fi

  # Enable JWT and multiroot mesh for security-ca-custom profiles
  if [[ "$WORKDIR" == *"security"* ]]; then
    yq eval '
      .spec.values.pilot.env.PILOT_JWT_ENABLE_REMOTE_JWKS = "true" |
      .spec.values.pilot.env.ISTIO_MULTIROOT_MESH = "true"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured pilot.env for security-ca-custom profile."
  fi

  # Enable QUIC listeners and multiroot mesh for QUIC tests
  if [[ "$WORKDIR" == *"quic"* ]]; then
    yq eval '
      .spec.values.pilot.env.PILOT_ENABLE_QUIC_LISTENERS = "true"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured pilot.env for QUIC tests."
  fi
}

function patch_gateway_config() {
  # Adds gateway-specific configurations based on test requirements
  if [[ "$WORKDIR" == *"filebased-tls-origination"* ]]; then
    # Add volume and volumeMount for egress gateway TLS origination tests
    echo "Detected filebased TLS origination test, adding secret volume configuration to egress gateway..."

    # Add volume to egress gateway deployment
    yq eval '
      .spec.template.spec.volumes = [{
        "name": "client-custom-certs",
        "secret": {
          "secretName": "egress-gw-cacerts",
          "optional": true
        }
      }]
    ' -i "${WORKDIR}/istio-egressgateway.yaml"

    # Add volumeMount to istio-proxy container
    yq eval '
      .spec.template.spec.containers[] |= (
        select(.name == "istio-proxy").volumeMounts = [{
          "name": "client-custom-certs",
          "mountPath": "/etc/certs/custom",
          "readOnly": true
        }]
      )
    ' -i "${WORKDIR}/istio-egressgateway.yaml"

    echo "Added egress gateway secret volume configuration for filebased TLS origination."
  fi

  if [[ "$WORKDIR" == *"quic"* ]]; then
    # Add UDP port for QUIC/HTTP3 connections to ingress gateway
    echo "Detected QUIC test, adding HTTP3/QUIC port configuration to ingress gateway..."

    # Add HTTP3/QUIC port to ingress gateway service
    yq eval '
      .spec.ports += [{
        "port": 443,
        "targetPort": 8443,
        "name": "http3",
        "protocol": "UDP"
      }]
    ' -i "${WORKDIR}/istio-ingressgateway.yaml"

    echo "Added HTTP3/QUIC port configuration to ingress gateway."
  fi
}

function patch_istiocni_config() {
  # Config set for "TestCNINeverEnrollsPodsInExcludedNamespaces" ambient cni test.
  # The "cni-excluded-ns" NS name hardcoded here, since it's being created after Istio
  # deployment by Sail and as a result could not be fetched dynamically.
  if [[ "$WORKDIR" == *"ambient-cni-"* ]]; then
      yq -i '.spec.values.cni.excludeNamespaces = ["istio-system", "cni-excluded-ns"]' "$TMP_ISTIOCNI"
      echo "Ambient CNI config applied"
  fi
}

function patch_ztunnel_config() {
  if [[ "$WORKDIR" == *"ambient-pqc"* ]]; then
      yq -i '.spec.values.ztunnel.env.COMPLIANCE_POLICY="pqc"' "$TMP_ZTUNNEL"
  fi
}

function wait_for_injection_webhook() {
  local attempts=0
  local max_attempts=30
  echo "Waiting for sidecar injection webhook to be ready..."
  while [ $attempts -lt $max_attempts ]; do
    local ca_bundle
    ca_bundle=$(kubectl get mutatingwebhookconfiguration istio-sidecar-injector \
      -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null || true)
    if [ -n "$ca_bundle" ]; then
      echo "Sidecar injection webhook is ready."
      return
    fi
    echo "Waiting for injection webhook caBundle... (attempt $((attempts+1))/$max_attempts)"
    sleep 10
    attempts=$((attempts+1))
  done
  echo "Warning: Sidecar injection webhook not ready after $max_attempts attempts"
}

# Install ingress and egress gateways
function install_gateways() {
  helm template -n "$NAMESPACE" istio-ingressgateway "${ROOT}"/manifests/charts/gateway --values "$INGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-ingressgateway.yaml
  helm template -n "$NAMESPACE" istio-egressgateway "${ROOT}"/manifests/charts/gateway --values "$EGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-egressgateway.yaml

  # Apply test-specific gateway patches
  patch_gateway_config

  oc apply -f "${WORKDIR}"/istio-ingressgateway.yaml
  oc apply -f "${WORKDIR}"/istio-egressgateway.yaml
  # patch egress gateway canonical-revision
  yq eval 'select(.kind == "Deployment") | .spec.template.metadata.labels["service.istio.io/canonical-revision"] = "latest"' "${WORKDIR}"/istio-egressgateway.yaml > "${WORKDIR}"/istio-egressgateway-deployment.yaml
  oc apply -f "${WORKDIR}"/istio-egressgateway-deployment.yaml
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-ingressgateway --timeout=60s || { echo "Failed to start istio-ingressgateway"; oc get pods -n "$NAMESPACE" -o wide; oc describe pod "$(oc get pods -n istio-system --no-headers | awk '$3=="ErrImagePull" {print $1}' | head -n 1)" -n istio-system; exit 1;}
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-egressgateway --timeout=60s || { echo "Failed to start istio-egressgateway";  kubectl get istios; oc get pods -n "$NAMESPACE" -o wide; exit 1;}
  echo "Gateways created."
}

function cleanup_istio() {
  set -euo pipefail

  echo "Starting Istio cleanup..."
  TIMEOUT_DURATION="120s"
  
  echo "Deleting IstioCNI resources from namespace $ISTIOCNI_NAMESPACE..."
  kubectl delete istiocni --all -n "$ISTIOCNI_NAMESPACE" --wait=true --timeout=$TIMEOUT_DURATION || {
    echo "Normal delete failed for $ISTIOCNI_NAMESPACE or timed out, applying force delete..."
    kubectl delete all --all -n "$ISTIOCNI_NAMESPACE" --force --grace-period=0 --wait=true
  }

  echo "Deleting ZTunnel resources from namespace $ZTUNNEL_NAMESPACE..."
  kubectl delete ztunnel --all -n "$ZTUNNEL_NAMESPACE" --wait=true --timeout=$TIMEOUT_DURATION || {
    echo "Normal delete failed for $ZTUNNEL_NAMESPACE or timed out, applying force delete..."
    kubectl delete all --all -n "$ZTUNNEL_NAMESPACE" --force --grace-period=0 --wait=true
  }

  echo "Deleting Istio resources from namespace $NAMESPACE..."
  kubectl delete istio --all -n "$NAMESPACE" --wait=true --timeout=$TIMEOUT_DURATION || {
    echo "Normal delete failed for $NAMESPACE or timed out, applying force delete..."
    kubectl delete all --all -n "$NAMESPACE" --force --grace-period=0 --wait=true
  }

  echo "Delete Istio, IstioCNI and Ztunnel namespaces"
  kubectl delete namespace "$ISTIOCNI_NAMESPACE" || true
  kubectl delete namespace "$ZTUNNEL_NAMESPACE" || true
  kubectl delete namespace "$NAMESPACE" || true

  echo "Cleanup completed successfully."
}

# ==================== Multicluster Functions ====================

function load_topology() {
  local topology_file="${INTEGRATION_TEST_TOPOLOGY_FILE}"
  if [ -z "$topology_file" ] || [ ! -f "$topology_file" ]; then
    echo "Error: INTEGRATION_TEST_TOPOLOGY_FILE not set or file not found: ${topology_file:-unset}"
    exit 1
  fi

  mapfile -t ALL_CLUSTER_NAMES < <(jq -r '.[].clusterName' "$topology_file")
  mapfile -t ALL_CLUSTER_NETWORKS < <(jq -r '.[].network' "$topology_file")
  mapfile -t ALL_CLUSTER_KUBECONFIGS < <(jq -r '.[].meta.kubeconfig // empty' "$topology_file")
  mapfile -t ALL_CLUSTER_PRIMARY_NAMES < <(jq -r '.[] | .primaryClusterName // .clusterName' "$topology_file")
  mapfile -t ALL_CLUSTER_CONFIG_NAMES < <(jq -r '.[] | .configClusterName // .primaryClusterName // .clusterName' "$topology_file")

  echo "Loaded topology with ${#ALL_CLUSTER_NAMES[@]} clusters:"
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    echo "  ${ALL_CLUSTER_NAMES[$idx]} (network: ${ALL_CLUSTER_NETWORKS[$idx]}, primary: ${ALL_CLUSTER_PRIMARY_NAMES[$idx]})"
  done
}

function is_primary() {
  local idx="$1"
  [ "${ALL_CLUSTER_PRIMARY_NAMES[$idx]}" = "${ALL_CLUSTER_NAMES[$idx]}" ]
}

function is_config() {
  local idx="$1"
  [ "${ALL_CLUSTER_CONFIG_NAMES[$idx]}" = "${ALL_CLUSTER_NAMES[$idx]}" ]
}

function is_remote() {
  local idx="$1"
  [ "${ALL_CLUSTER_PRIMARY_NAMES[$idx]}" != "${ALL_CLUSTER_NAMES[$idx]}" ]
}

function get_primary_index() {
  local remote_idx="$1"
  local primary_name="${ALL_CLUSTER_PRIMARY_NAMES[$remote_idx]}"
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    if [ "${ALL_CLUSTER_NAMES[$idx]}" = "$primary_name" ]; then
      echo "$idx"
      return
    fi
  done
  echo "Error: Primary cluster '$primary_name' not found in topology" >&2
  exit 1
}

function switch_cluster() {
  local idx="$1"
  local cluster_name="${ALL_CLUSTER_NAMES[$idx]}"
  local kubeconfig="${ALL_CLUSTER_KUBECONFIGS[$idx]}"
  if [ -n "$kubeconfig" ]; then
    export KUBECONFIG="$kubeconfig"
  fi
  kubectl config use-context "$cluster_name" 2>/dev/null || true
  echo "Switched to cluster: $cluster_name (KUBECONFIG=$KUBECONFIG)"
}

function download_execute_converter_for_role() {
  local role="$1"
  case "$role" in
    primary) IOP_FILE="${WORKDIR}/iop.yaml" ;;
    remote)  IOP_FILE="${WORKDIR}/remote.yaml" ;;
    config)  IOP_FILE="${WORKDIR}/config.yaml" ;;
  esac
  SAIL_IOP_FILE="$(basename "${IOP_FILE%.yaml}")-sail.yaml"
  download_execute_converter
}

function install_eastwest_gateway() {
  local network="$1"
  echo "Installing east-west gateway for network $network..."
  local tmp_manifest="${WORKDIR}/istio-eastwestgateway.yaml"

  if [ "$AMBIENT" == "true" ]; then
    cp "$EASTWEST_GATEWAY_AMBIENT_MANIFEST" "$tmp_manifest"
    yq -i ".metadata.namespace = \"$NAMESPACE\"" "$tmp_manifest"
    yq -i ".metadata.labels[\"topology.istio.io/network\"] = \"$network\"" "$tmp_manifest"
    oc apply -f "$tmp_manifest"
    echo "Ambient east-west gateway created for network $network."
  else
    helm template -n "$NAMESPACE" istio-eastwestgateway "${ROOT}"/manifests/charts/gateway \
      --values "$EASTWEST_GATEWAY_VALUES" \
      --set networkGateway="$network" > "$tmp_manifest"
    oc apply -f "$tmp_manifest"
    oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-eastwestgateway --timeout=120s
    echo "East-west gateway created for network $network."
  fi
}

function get_eastwest_gateway_address() {
  local attempts=0
  local max_attempts=30
  local addr=""
  while [ $attempts -lt $max_attempts ]; do
    addr=$(kubectl -n "$NAMESPACE" get svc istio-eastwestgateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [ -n "$addr" ]; then
      echo "$addr"
      return
    fi
    echo "Waiting for east-west gateway external IP... (attempt $((attempts+1))/$max_attempts)"
    sleep 10
    attempts=$((attempts+1))
  done
  echo "Error: Failed to get east-west gateway external IP after $max_attempts attempts" >&2
  exit 1
}

function set_cluster_identity() {
  local idx="$1"
  local cluster_name="${ALL_CLUSTER_NAMES[$idx]}"
  local network="${ALL_CLUSTER_NETWORKS[$idx]}"
  yq eval ".spec.values.global.multiCluster.clusterName = \"$cluster_name\"" -i "$WORKDIR/$SAIL_IOP_FILE"
  yq eval ".spec.values.global.network = \"$network\"" -i "$WORKDIR/$SAIL_IOP_FILE"
  yq eval ".spec.values.global.meshID = \"mesh1\"" -i "$WORKDIR/$SAIL_IOP_FILE"
  echo "Set cluster identity: clusterName=$cluster_name, network=$network"
}

function install_multicluster() {
  load_topology

  # Phase 1: Config-remote clusters (CRDs/RBAC, no remotePilotAddress yet)
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    if is_remote "$idx" && is_config "$idx"; then
      echo "=== Phase 1: Installing config-remote cluster ${ALL_CLUSTER_NAMES[$idx]} ==="
      switch_cluster "$idx"
      download_execute_converter_for_role "config"
      set_cluster_identity "$idx"
      install_istio_cni
      if [ "$AMBIENT" == "true" ]; then
        install_ztunnel "$idx"
      fi
      install_istio
    fi
  done

  # Phase 2: Primary clusters (istiod + all gateways including east-west)
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    if is_primary "$idx"; then
      echo "=== Phase 2: Installing primary cluster ${ALL_CLUSTER_NAMES[$idx]} ==="
      switch_cluster "$idx"
      download_execute_converter_for_role "primary"
      set_cluster_identity "$idx"
      install_istio_cni
      if [ "$AMBIENT" == "true" ]; then
        install_ztunnel "$idx"
      fi
      install_istio
      wait_for_injection_webhook
      install_gateways
      install_eastwest_gateway "${ALL_CLUSTER_NETWORKS[$idx]}"
    fi
  done

  # Phase 3: Remote clusters (with remotePilotAddress from primary's EW gateway)
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    if is_remote "$idx" && ! is_config "$idx"; then
      echo "=== Phase 3: Installing remote cluster ${ALL_CLUSTER_NAMES[$idx]} ==="

      # Get remotePilotAddress from primary's east-west gateway
      local primary_idx
      primary_idx=$(get_primary_index "$idx")
      switch_cluster "$primary_idx"
      local pilot_addr
      pilot_addr=$(get_eastwest_gateway_address)

      switch_cluster "$idx"
      download_execute_converter_for_role "remote"
      set_cluster_identity "$idx"
      yq eval ".spec.values.global.remotePilotAddress = \"$pilot_addr\"" -i "$WORKDIR/$SAIL_IOP_FILE"
      echo "Set remotePilotAddress=$pilot_addr for remote cluster ${ALL_CLUSTER_NAMES[$idx]}"

      install_istio_cni
      if [ "$AMBIENT" == "true" ]; then
        install_ztunnel "$idx"
      fi
      install_istio
      wait_for_injection_webhook
      install_gateways
      install_eastwest_gateway "${ALL_CLUSTER_NETWORKS[$idx]}"
    fi
  done

  # Phase 4: Update config-remote clusters with remotePilotAddress
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    if is_remote "$idx" && is_config "$idx"; then
      echo "=== Phase 4: Updating config-remote cluster ${ALL_CLUSTER_NAMES[$idx]} with remotePilotAddress ==="

      local primary_idx
      primary_idx=$(get_primary_index "$idx")
      switch_cluster "$primary_idx"
      local pilot_addr
      pilot_addr=$(get_eastwest_gateway_address)

      switch_cluster "$idx"
      kubectl patch istio default -n "$NAMESPACE" --type merge \
        -p "{\"spec\":{\"values\":{\"global\":{\"remotePilotAddress\":\"$pilot_addr\"}}}}"
      echo "Patched remotePilotAddress=$pilot_addr for config-remote cluster ${ALL_CLUSTER_NAMES[$idx]}"
      oc -n "$NAMESPACE" wait --for=condition=Available deployment/istiod --timeout=240s || { sleep 60; }
    fi
  done
}

function cleanup_multicluster() {
  load_topology
  for idx in "${!ALL_CLUSTER_NAMES[@]}"; do
    echo "Cleaning up cluster ${ALL_CLUSTER_NAMES[$idx]}..."
    switch_cluster "$idx"
    cleanup_istio
  done
}

# ==================== Entry Point ====================

if [ "$1" = "install" ]; then
  if [ "${TOPOLOGY:-SINGLE_CLUSTER}" != "SINGLE_CLUSTER" ]; then
    install_multicluster || { echo "Failed multicluster install"; exit 1; }
  else
    download_execute_converter || { echo "Failed to execute converter"; exit 1; }
    install_istio_cni || { echo "Failed to install Istio CNI"; exit 1; }
    if [ "$AMBIENT" == "true" ]; then
      install_ztunnel || { echo "Failed to install ZTunnel"; exit 1; }
    fi
    install_istio || { echo "Failed to install Istio"; exit 1; }
    install_gateways || { echo "Failed to install gateways"; exit 1; }
  fi
elif [ "$1" = "cleanup" ]; then
  if [ "$SKIP_CLEANUP" = "true" ]; then
    echo "Skipping cleanup because SKIP_CLEANUP is set to true."
  elif [ "${TOPOLOGY:-SINGLE_CLUSTER}" != "SINGLE_CLUSTER" ]; then
    cleanup_multicluster || { echo "Failed multicluster cleanup"; exit 1; }
  else
    cleanup_istio || { echo "Failed to cleanup cluster"; exit 1; }
  fi
fi

