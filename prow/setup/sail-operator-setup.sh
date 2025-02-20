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

exec > >(tee -a "$2"/sail-operator-setup.log) 2>&1
# Exit immediately for non zero status
set -e
# Check unset variables
set -u
# Print commands
set -x

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
IOP_FILE="$2"/iop.yaml
SAIL_IOP_FILE="$(basename "${IOP_FILE%.yaml}")-sail.yaml"

ISTIO_VERSION="${ISTIO_VERSION:-v1.24.1}"
INGRESS_GATEWAY_SVC_NAMESPACE="${INGRESS_GATEWAY_SVC_NAMESPACE:-istio-system}"
ISTIOCNI_NAMESPACE="${ISTIOCNI_NAMESPACE:-istio-cni}"

ISTIOCNI="${PROW}/config/sail-operator/istioCNI-cr.yaml"
INGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/ingress-gateway-values.yaml"
EGRESS_GATEWAY_VALUES="${PROW}/config/sail-operator/egress-gateway-values.yaml"

CONVERTER_ADDRESS="https://raw.githubusercontent.com/istio-ecosystem/sail-operator/main/tools/configuration-converter.sh"
CONVERTER_SCRIPT=$(basename $CONVERTER_ADDRESS)

function download_execute_converter(){
  cd ${PROW}
  curl -fsSL "$CONVERTER_ADDRESS" -o "$CONVERTER_SCRIPT" || { echo "Failed to download converter script"; exit 1; }
  chmod +x $CONVERTER_SCRIPT
  bash $CONVERTER_SCRIPT "$IOP_FILE" -v "$ISTIO_VERSION" -n $INGRESS_GATEWAY_SVC_NAMESPACE
  rm $CONVERTER_SCRIPT
}

function install_istio_cni(){
  oc create namespace "${ISTIOCNI_NAMESPACE}" || true
  TMP_ISTIOCNI=$WORKDIR/istioCNI.yaml
  cp "$ISTIOCNI" "$TMP_ISTIOCNI"
  yq -i ".spec.namespace=\"$ISTIOCNI_NAMESPACE\"" "$TMP_ISTIOCNI"
  yq -i ".spec.version=\"$ISTIO_VERSION\"" "$TMP_ISTIOCNI"
  oc apply -f "$TMP_ISTIOCNI"
  echo "istioCNI created."
}

function install_istiod(){
  # overwrite sailoperator version before applying it
  if [ "${SAIL_API_VERSION:-}" != "" ]; then
    yq -i eval ".apiVersion = \"sailoperator.io/$SAIL_API_VERSION\"" "$WORKDIR/$SAIL_IOP_FILE"
  fi
  oc apply -f "$WORKDIR/$SAIL_IOP_FILE"
  echo "istiod created."
}

# Install ingress and egress gateways
function install_gateways(){
  helm template -n $INGRESS_GATEWAY_SVC_NAMESPACE istio-ingressgateway ${ROOT}/manifests/charts/gateway --values $INGRESS_GATEWAY_VALUES > ${WORKDIR}/istio-ingressgateway.yaml
  oc apply -f ${WORKDIR}/istio-ingressgateway.yaml
  helm template -n $INGRESS_GATEWAY_SVC_NAMESPACE istio-egressgateway ${ROOT}/manifests/charts/gateway --values $EGRESS_GATEWAY_VALUES > ${WORKDIR}/istio-egressgateway.yaml
  oc apply -f ${WORKDIR}/istio-egressgateway.yaml
  echo "Gateways created."

}

function cleanup_istio(){
  oc delete istio/default
  oc delete istioCNI/default
  oc delete all --selector app=istio-egressgateway -n $INGRESS_GATEWAY_SVC_NAMESPACE
  oc delete all --selector app=istio-ingressgateway -n $INGRESS_GATEWAY_SVC_NAMESPACE
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
