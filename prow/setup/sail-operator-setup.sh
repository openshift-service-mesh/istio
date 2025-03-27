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

ISTIO_VERSION="${ISTIO_VERSION:-v1.24-latest}"
NAMESPACE="${NAMESPACE:-istio-system}"
ISTIOCNI_NAMESPACE="${ISTIOCNI_NAMESPACE:-istio-cni}"

ISTIOCNI="${PROW}/config/sail-operator/istio-cni.yaml"
INGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/ingress-gateway-values.yaml"
EGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/egress-gateway-values.yaml"

CONVERTER_ADDRESS="https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/tools/configuration-converter.sh"
CONVERTER_SCRIPT=$(basename $CONVERTER_ADDRESS)

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

function install_istiod(){
  # overwrite sailoperator version before applying it
  oc create namespace "${NAMESPACE}" || true
  if [ "${SAIL_API_VERSION:-}" != "" ]; then
    yq -i eval ".apiVersion = \"sailoperator.io/$SAIL_API_VERSION\"" "$WORKDIR/$SAIL_IOP_FILE"
  fi
  oc apply -f "$WORKDIR/$SAIL_IOP_FILE" || { echo "Failed to install istiod"; kubectl get istio default -o yaml;}
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istiod --timeout=240s || { sleep 60; }
  echo "istiod created."
}

# Install ingress and egress gateways
function install_gateways(){
  helm template -n "$NAMESPACE" istio-ingressgateway "${ROOT}"/manifests/charts/gateway --values "$INGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-ingressgateway.yaml
  oc apply -f "${WORKDIR}"/istio-ingressgateway.yaml
  helm template -n "$NAMESPACE" istio-egressgateway "${ROOT}"/manifests/charts/gateway --values "$EGRESS_GATEWAY_VALUES" > "${WORKDIR}"/istio-egressgateway.yaml
  oc apply -f "${WORKDIR}"/istio-egressgateway.yaml
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-ingressgateway --timeout=60s || { echo "Failed to start istio-ingressgateway"; oc get pods -n "$NAMESPACE" -o wide; oc describe pod $(oc get pods -n istio-system --no-headers | awk '$3=="ErrImagePull" {print $1}' | head -n 1) -n istio-system;}
  oc -n "$NAMESPACE" wait --for=condition=Available deployment/istio-egressgateway --timeout=60s || { echo "Failed to start istio-egressgateway";  kubectl get istios; oc get pods -n "$NAMESPACE" -o wide;}
  echo "Gateways created."

}

function cleanup_istio(){
  kubectl delete all --all -n $ISTIOCNI_NAMESPACE
  kubectl delete all --all -n $NAMESPACE
  kubectl delete istios.sailoperator.io --all --all-namespaces --wait=true
  kubectl get clusterrole | grep istio | awk '{print $1}' | xargs kubectl delete clusterrole
  kubectl get clusterrolebinding | grep istio | awk '{print $1}' | xargs kubectl delete clusterrolebinding
  echo "Cleanup completed."
}

if [ "$1" = "install" ]; then
  download_execute_converter || { echo "Failed to execute converter"; exit 1; }
  install_istio_cni || { echo "Failed to install Istio CNI"; exit 1; }
  install_istiod || { echo "Failed to install Istiod"; exit 1; }
  install_gateways || { echo "Failed to install gateways"; exit 1; }
elif [ "$1" = "cleanup" ]; then
  cleanup_istio || { echo "Failed to cleanup cluster"; exit 1; }
fi
