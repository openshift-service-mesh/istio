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

CONVERTER_BRANCH="${CONVERTER_BRANCH:-main}"

# get istio version from versions.yaml
VERSION_FILE="https://raw.githubusercontent.com/istio-ecosystem/sail-operator/$CONVERTER_BRANCH/pkg/istioversion/versions.yaml"
if [ -z "${ISTIO_VERSION:-}" ]; then
  ISTIO_VERSION="$(curl -s "$VERSION_FILE" | \
    grep -E 'name: v[0-9]+\.[0-9]+-latest' | \
    sed -E 's/.*(v[0-9]+\.[0-9]+)-latest.*/\1/' | \
    sort -Vr | head -n1)-latest"
fi
  
NAMESPACE="${NAMESPACE:-istio-system}"
ISTIOCNI_NAMESPACE="${ISTIOCNI_NAMESPACE:-istio-cni}"

ISTIOCNI="${PROW}/config/sail-operator/istio-cni.yaml"
INGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/ingress-gateway-values.yaml"
EGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/egress-gateway-values.yaml"

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
  oc apply -f "$TMP_ISTIOCNI"
  echo "istioCNI created."
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
  if [[ "$WORKDIR" == *"telemetry-tracing-zipkin"* ]]; then
  # Workaround until https://github.com/istio/istio/pull/55408 is merged
    yq eval '
      .spec.values.meshConfig.enableTracing = true |
      .spec.values.pilot.traceSampling = 100.0 |
      .spec.values.global.proxy.tracer = "zipkin"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Configured tracing for Zipkin."

  elif [[ "$WORKDIR" == *"pilot-"* ]]; then
    # Fix for TestTraffic/dns/a/ tests
    yq eval '
      .spec.values.meshConfig.defaultConfig.proxyMetadata.ISTIO_META_DNS_CAPTURE = "true"
    ' -i "$WORKDIR/$SAIL_IOP_FILE"
    echo "Enabled DNS capture for Istio proxy."
    
  fi
}

SECRET_NAME="istio-ca-secret"
WEBHOOK_FILE="$PROW/config/sail-operator/validatingwebhook.yaml"

function install_validatingwebhook(){
  # Workaround until https://github.com/istio-ecosystem/sail-operator/issues/749 is fixed
  CA_BUNDLE=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | grep "ca-cert" | awk '{print $2}')

  # If not found, sleep for 5 seconds and retry once
  if [ -z "$CA_BUNDLE" ]; then
    echo "Secret not found. Sleeping for 10 seconds before retrying..."
    sleep 10
    
    # Retry once
    CA_BUNDLE=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | grep "ca-cert" | awk '{print $2}')
    
    if [ -z "$CA_BUNDLE" ]; then
      echo "Secret still not found after retry. Exiting."
      exit 1
    fi
  fi  

  sed -i "s|<base64-encoded-CA-cert>|$CA_BUNDLE|g" "$WEBHOOK_FILE"
  kubectl apply -f "$WEBHOOK_FILE"
  sed -i "s|$CA_BUNDLE|<base64-encoded-CA-cert>|g" "$WEBHOOK_FILE"
}

# Install ingress and egress gateways
function install_gateways(){
  helm template -n "$NAMESPACE" istio-ingressgateway "${ROOT}"/manifests/charts/gateway --values "$INGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-ingressgateway.yaml
  oc apply -f "${WORKDIR}"/istio-ingressgateway.yaml
  helm template -n "$NAMESPACE" istio-egressgateway "${ROOT}"/manifests/charts/gateway --values "$EGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-egressgateway.yaml
  oc apply -f "${WORKDIR}"/istio-egressgateway.yaml
  # patch egress gateway canonical-revision
  yq eval 'select(.kind == "Deployment") | .spec.template.metadata.labels["service.istio.io/canonical-revision"] = "latest"' "${WORKDIR}"/istio-egressgateway.yaml > "${WORKDIR}"/istio-egressgateway-deployment.yaml
  oc apply -f "${WORKDIR}"/istio-egressgateway-deployment.yaml
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-ingressgateway --timeout=60s || { echo "Failed to start istio-ingressgateway"; oc get pods -n "$NAMESPACE" -o wide; oc describe pod $(oc get pods -n istio-system --no-headers | awk "$3==\"ErrImagePull\" {print $1}" | head -n 1) -n istio-system; exit 1;}
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-egressgateway --timeout=60s || { echo "Failed to start istio-egressgateway";  kubectl get istios; oc get pods -n "$NAMESPACE" -o wide; exit 1;}
  echo "Gateways created."
}

function cleanup_istio() {
  set -euo pipefail

  echo "Starting Istio cleanup..."
  TIMEOUT_DURATION="120s"
  
  echo "Deleting Istio resources from namespace $ISTIOCNI_NAMESPACE..."
  kubectl delete all --all -n "$ISTIOCNI_NAMESPACE" --wait=true --timeout=$TIMEOUT_DURATION || {
    echo "Normal delete failed for $ISTIOCNI_NAMESPACE or timed out, applying force delete..."
    kubectl delete all --all -n "$ISTIOCNI_NAMESPACE" --force --grace-period=0 --wait=true
  }

  echo "Deleting Istio resources from namespace $NAMESPACE..."
  kubectl delete all --all -n "$NAMESPACE" --wait=true --timeout=$TIMEOUT_DURATION || {
    echo "Normal delete failed for $NAMESPACE or timed out, applying force delete..."
    kubectl delete all --all -n "$NAMESPACE" --force --grace-period=0 --wait=true
  }

  echo "Cleanup completed successfully."
}

MINOR_VERSION=$(echo "$ISTIO_VERSION" | sed 's/-latest//' | awk -F. '
{
  gsub(/^v/, "", $1);
  major = $1;
  minor = $2;
  patch = ($3 == "" ? "0" : $3);
  printf("v%s.%s.%s\n", major, minor, patch);
}')

if [ "$1" = "install" ]; then
  download_execute_converter || { echo "Failed to execute converter"; exit 1; }
  install_istio_cni || { echo "Failed to install Istio CNI"; exit 1; }
  install_istio || { echo "Failed to install Istio"; exit 1; }
  install_validatingwebhook || { echo "Failed to install validatingwebhook"; exit 1; }
  install_gateways || { echo "Failed to install gateways"; exit 1; }
elif [ "$1" = "cleanup" ]; then
  if [ "$SKIP_CLEANUP" = "true" ]; then
    echo "Skipping cleanup because SKIP_CLEANUP is set to true."
  else
    cleanup_istio || { echo "Failed to cleanup cluster"; exit 1; }
  fi
fi

