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

# Validates that all OpenShift cluster operators are stable before running tests.
#
# When kube-apiserver is rolling, it terminates oc exec WebSocket sessions. Running
# this check *before* any oc exec call prevents those mid-session drops from being
# mistaken for test failures.
#
# Usage:
#   Standalone:  ./prow/check-cluster-ready.sh
#   Sourced:     source ./prow/check-cluster-ready.sh   # provides check_cluster_operators()
#
# Environment:
#   CLUSTER_OPERATOR_TIMEOUT  seconds to wait before giving up (default: 600)

check_cluster_operators() {
  if ! command -v jq &> /dev/null; then
    echo "ERROR: jq is required for the cluster operator health check. Please install jq." >&2
    return 1
  fi

  local timeout_seconds=${CLUSTER_OPERATOR_TIMEOUT:-600}
  local end_time=$(( $(date +%s) + timeout_seconds ))
  echo "Validating OpenShift cluster operators are stable (timeout: ${timeout_seconds}s)..."

  while [ "$(date +%s)" -lt "$end_time" ]; do
    local oc_output unstable_operators
    if ! oc_output=$(oc get clusteroperator -o json 2>&1); then
      echo "WARNING: 'oc get clusteroperator' failed (transient error?): ${oc_output}" >&2
      sleep 15
      continue
    fi

    if ! unstable_operators=$(jq '[.items[] | select(.status.conditions[] | (.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True"))] | length' <<< "${oc_output}"); then
      echo "WARNING: jq failed to parse clusteroperator output" >&2
      sleep 15
      continue
    fi

    if [[ $unstable_operators -eq 0 ]]; then
      echo "All cluster operators are stable."
      return 0
    fi

    echo "WARNING: ${unstable_operators} unstable operator(s):" >&2
    jq -r '.items[] | select(.status.conditions[] | (.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True")) | .metadata.name as $name | .status.conditions[] | select((.type == "Available" and .status == "False") or (.type == "Progressing" and .status == "True") or (.type == "Degraded" and .status == "True")) | "  \($name): \(.type)=\(.status) — \(.message)"' <<< "${oc_output}" >&2
    sleep 15
  done

  echo "ERROR: Timeout reached. Not all cluster operators are stable." >&2
  oc get clusteroperator >&2 || true
  return 1
}

# When executed directly (not sourced), run the check and exit with its status.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  check_cluster_operators
fi
