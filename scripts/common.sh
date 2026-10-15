#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/.state}"

AWS_REGION="${AWS_REGION:-us-east-2}"
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-${AWS_REGION}}"
CLUSTER_NAME="${CLUSTER_NAME:-runai-fractioning-blog}"
EKS_VERSION="${EKS_VERSION:-1.36}"
GPU_INSTANCE_TYPE="${GPU_INSTANCE_TYPE:-g5.xlarge}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-615.71.09}"
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

render_cluster_config() {
  sed \
    -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
    -e "s/__AWS_REGION__/${AWS_REGION}/g" \
    -e "s/__EKS_VERSION__/${EKS_VERSION}/g" \
    "${ROOT_DIR}/config/eksctl-cluster.yaml.tpl" \
    >"${STATE_DIR}/eksctl-cluster.yaml"
}

render_gpu_nodegroup_config() {
  local ami_id="$1"
  sed \
    -e "s/__CLUSTER_NAME__/${CLUSTER_NAME}/g" \
    -e "s/__AWS_REGION__/${AWS_REGION}/g" \
    -e "s/__EKS_VERSION__/${EKS_VERSION}/g" \
    -e "s/__GPU_INSTANCE_TYPE__/${GPU_INSTANCE_TYPE}/g" \
    -e "s/__AMI_ID__/${ami_id}/g" \
    -e "s/__NVIDIA_DRIVER_VERSION__/${NVIDIA_DRIVER_VERSION}/g" \
    "${ROOT_DIR}/config/eksctl-gpu-nodegroup.yaml.tpl" \
    >"${STATE_DIR}/eksctl-gpu-nodegroup.yaml"
}
