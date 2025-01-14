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

# This script is used to convert  istio config to and sail operator on and install on OpenShift.
# The integration test runtime is calling this script automatically if istio.test.kube.controlPlaneInstaller parameter set.
# The constants like version, namespaces etc are being read from istio/prow/config/sail_config/sail_operator_constants.env 
# Any necessary additional constant or template file can be added under istio/prow/config/sail_config     
# The output of this sctipt is printed under working directory set by: --istio.test.work_dir/sail_operator_setup_logs.txt

exec 19>$1/sail_operator_setup_logs.txt
BASH_XTRACEFD=19

set -e
set -x
WD=$(dirname "$0")
SETUP=$(dirname "$WD")
PROW=$(dirname "$SETUP")
ROOT=$(dirname "$PROW")
WORKDIR=$1

IOP_FILE="iop.yaml"
SAIL_IOP_FILE="sail_iop.yaml" 
SAIL_IOP="$WORKDIR/$SAIL_IOP_FILE"

source "${PROW}/config/sail_config/sail_operator_constants.env"

INGRESS_GATEWAY_VALUES="${PROW}/config/sail_config/ingress-gateway-values.yaml"
EGRESS_GATEWAY_VALUES="${PROW}/config/sail_config/egress-gateway-values.yaml"

#This function is a workaround since yq -i command is not working on /tmp directory     
function update_iop_yaml(){
  cd $WORKDIR
  cp $IOP_FILE $SAIL_IOP_FILE
  arr=("$@")
  for i in "${arr[@]}";
    do
      cat $SAIL_IOP_FILE | yq $i > tmp.yaml
      mv tmp.yaml $SAIL_IOP_FILE
    done
    #Convert boolean values to string if it is under *.env
    SPEC_FIELDS="$(yq -r $IOP_FILE | yq '(.spec.values.[].env)')"
    echo $SPEC_FIELDS
    if [ -n "$SPEC_FIELDS" ] ;then
    cat $SAIL_IOP_FILE | yq '(.spec.values.[].env.[] | select(. == true)) |= "true"'  > tmp.yaml
    cat tmp.yaml | yq '(.spec.values.[].env.[] | select(. == false)) |= "false"' | sed '/env: \[\]/d'  > $SAIL_IOP_FILE
    rm tmp.yaml
    fi
    chmod +x $SAIL_IOP_FILE
    echo "Sail operator configuration file created."
}

function install_istiod(){
  oc apply -f $SAIL_IOP
  echo "Sail operator installed."
}

function install_istio_cni(){
  oc create namespace istio-cni || true
  ISTIOCNI="${PROW}/config/sail_config/istioCNI-cr.yaml"
  yq -r $ISTIOCNI | yq ".spec.version=\"$ISTIO_VERSION\"" > ${WORKDIR}/tmp.yaml
  oc apply -f ${WORKDIR}/tmp.yaml
  rm ${WORKDIR}/tmp.yaml
  echo "Istio CNI created."
}

# Install ingress and egress gateways
function install_gateways(){
  cd $PROW
  helm template -n $INGRESS_GATEWAY_SVC_NAMESPACE istio-ingressgateway ../manifests/charts/gateway --values $INGRESS_GATEWAY_VALUES > ${WORKDIR}/tmp_ingress.yaml
  oc apply -f ${WORKDIR}/tmp_ingress.yaml
  helm template -n $INGRESS_GATEWAY_SVC_NAMESPACE istio-egressgateway ../manifests/charts/gateway --values $EGRESS_GATEWAY_VALUES > ${WORKDIR}/tmp_egress.yaml
  oc apply -f ${WORKDIR}/tmp_egress.yaml
  rm ${WORKDIR}/tmp_ingress.yaml ${WORKDIR}/tmp_egress.yaml
  echo "Gateways created."

}

function cleanup(){
  oc delete istio/default
  if [ "$ENABLE_CNI" == "true" ]; then
    oc delete istioCNI/default
  fi
  oc delete all --selector app=istio-egressgateway -n $INGRESS_GATEWAY_SVC_NAMESPAC
  oc delete all --selector app=istio-ingressgateway -n $INGRESS_GATEWAY_SVC_NAMESPACE
}

if [ "$2" = "install" ]; then
  sail_api=".apiVersion=\"sailoperator.io/v1alpha1\""
  sail_kind=".kind=\"Istio\""
  sail_metadata_name=".metadata.name=\"default\""
  sail_istio_version=".spec.version=\"$ISTIO_VERSION\""
  sail_istio_namespace=".spec.namespace=\"$INGRESS_GATEWAY_SVC_NAMESPACE\""

  sail_config_array=($sail_api $sail_kind $sail_istio_version $sail_istio_namespace $sail_metadata_name)

  update_iop_yaml "${sail_config_array[@]}"
  install_istiod 
  if [ "$ENABLE_CNI" == "true" ]; then
    install_istio_cni
  fi
  install_gateways
elif [ "$2" = "cleanup" ]; then
  cleanup
fi
