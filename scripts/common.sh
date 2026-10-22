#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state}"

AWS_REGION="${AWS_REGION:-us-east-2}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
CLUSTER_NAME="${CLUSTER_NAME:-runai-fractioning-blog}"
EKS_VERSION="${EKS_VERSION:-1.36}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.xlarge}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-615.71.10}"
KAI_VERSION="${KAI_VERSION:-v0.18.5}"
GPU_OPERATOR_VERSION="${GPU_OPERATOR_VERSION:-v26.7.1}"
KUBECONFIG="${KUBECONFIG:-${STATE_DIR}/kubeconfig}"

export AWS_REGION AWS_DEFAULT_REGION CLUSTER_NAME EKS_VERSION
export GPU_INSTANCE_TYPE NVIDIA_DRIVER_VERSION KAI_VERSION GPU_OPERATOR_VERSION
export KUBECONFIG

mkdir -p "${STATE_DIR}"

require_tool() {
  local tool="$1"
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "Required command not found: ${tool}" >&2
    return 1
  fi
}

require_aws_identity() {
  aws sts get-caller-identity >/dev/null
}

helm_rollback_flag() {
  if helm upgrade --help | grep -q -- '--rollback-on-failure'; then
    printf '%s\n' '--rollback-on-failure'
  else
    printf '%s\n' '--atomic'
  fi
}

kube_context() {
  local context
  context="$(kubectl --kubeconfig "${KUBECONFIG}" config current-context 2>/dev/null || true)"
  if [[ -z "${context}" ]]; then
    context="$(kubectl --kubeconfig "${KUBECONFIG}" config get-contexts -o name | head -n 1)"
  fi
  if [[ -z "${context}" ]]; then
    echo "No Kubernetes context found in ${KUBECONFIG}" >&2
    return 1
  fi
  printf '%s\n' "${context}"
}

run_kubectl() {
  kubectl --kubeconfig "${KUBECONFIG}" --context "$(kube_context)" "$@"
}

# Retries a kubectl call against the cluster API to absorb a genuinely
# transient failure, such as a freshly-created endpoint's DNS record taking a
# few seconds to become locally resolvable. Callers MUST ensure the kubeconfig
# already targets the correct, current endpoint (e.g. via `aws eks
# update-kubeconfig`) before relying on this: retrying cannot recover from a
# stale or wrong endpoint, which never resolves no matter how many attempts.
# Each attempt carries its own --request-timeout, so a single hung call
# cannot stall past that bound; combined with the attempt cap, total elapsed
# time is bounded by roughly attempts * (timeout + delay) rather than by
# attempt count alone. Succeeds as soon as one attempt succeeds; fails with
# the last error after the final attempt.
run_kubectl_retry() {
  local attempts="${API_RETRY_ATTEMPTS:-8}"
  local delay_seconds="${API_RETRY_DELAY_SECONDS:-5}"
  local request_timeout="${API_RETRY_REQUEST_TIMEOUT:-10s}"
  local attempt=1
  while true; do
    if run_kubectl --request-timeout "${request_timeout}" "$@"; then
      return 0
    fi
    if (( attempt >= attempts )); then
      echo "run_kubectl failed after ${attempts} attempts: kubectl $*" >&2
      return 1
    fi
    echo "kubectl call did not succeed yet (attempt ${attempt}/${attempts}); retrying in ${delay_seconds}s in case the endpoint's DNS record is still propagating." >&2
    sleep "${delay_seconds}"
    attempt=$((attempt + 1))
  done
}

render_cluster_config() {
  sed \
    -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
    -e "s/__AWS_REGION__/${AWS_REGION}/g" \
    -e "s/__EKS_VERSION__/${EKS_VERSION}/g" \
    "${ROOT_DIR}/config/eksctl-cluster.yaml.tpl" \
    >"${STATE_DIR}/eksctl-cluster.yaml"
}

render_gpu_nodegroup_config() {
  # Use ${N:-} so a missing argument under `set -u` (every production caller
  # runs set -euo pipefail) surfaces the explicit error below rather than a
  # cryptic "unbound variable" abort before the guard can run.
  local ami_id="${1:-}"
  local nvidia_driver_version="${2:-}"
  if [[ -z "${ami_id}" ]]; then
    echo "render_gpu_nodegroup_config requires the AMI id as its first argument." >&2
    return 1
  fi
  if [[ -z "${nvidia_driver_version}" ]]; then
    echo "render_gpu_nodegroup_config requires the actual installed driver version as its second argument." >&2
    return 1
  fi
  sed \
    -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
    -e "s/__AWS_REGION__/${AWS_REGION}/g" \
    -e "s/__EKS_VERSION__/${EKS_VERSION}/g" \
    -e "s/__GPU_INSTANCE_TYPE__/${GPU_INSTANCE_TYPE}/g" \
    -e "s/__AMI_ID__/${ami_id}/g" \
    -e "s/__NVIDIA_DRIVER_VERSION__/${nvidia_driver_version}/g" \
    "${ROOT_DIR}/config/eksctl-gpu-nodegroup.yaml.tpl" \
    >"${STATE_DIR}/eksctl-gpu-nodegroup.yaml"
}
