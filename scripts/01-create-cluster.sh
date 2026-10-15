#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl; do
  require_tool "${tool}"
done
require_aws_identity

render_cluster_config

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "EKS cluster ${CLUSTER_NAME} already exists; skipping creation."
  aws eks update-kubeconfig \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --kubeconfig "${KUBECONFIG}" \
    --alias "${CLUSTER_NAME}"
else
  eksctl create cluster \
    --config-file "${STATE_DIR}/eksctl-cluster.yaml" \
    --kubeconfig "${KUBECONFIG}" \
    --set-kubeconfig-context=false \
    --timeout 60m \
    --color false
fi

kubectl --kubeconfig "${KUBECONFIG}" config use-context "$(kube_context)" >/dev/null
run_kubectl get nodes -o wide
