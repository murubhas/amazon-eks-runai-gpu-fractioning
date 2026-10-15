#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl helm packer jq curl; do
  require_tool "${tool}"
done

require_aws_identity

echo "AWS identity"
aws sts get-caller-identity --output table

echo
echo "Tool versions"
aws --version
eksctl version
kubectl version --client=true
helm version --short
packer version | head -n 1
jq --version

echo
echo "Configuration"
printf 'AWS_PROFILE=%s\n' "${AWS_PROFILE:-<default credential chain>}"
printf 'AWS_REGION=%s\n' "${AWS_REGION}"
printf 'CLUSTER_NAME=%s\n' "${CLUSTER_NAME}"
printf 'EKS_VERSION=%s\n' "${EKS_VERSION}"
printf 'GPU_INSTANCE_TYPE=%s\n' "${GPU_INSTANCE_TYPE}"
printf 'NVIDIA_DRIVER_VERSION=%s\n' "${NVIDIA_DRIVER_VERSION}"
printf 'KUBECONFIG=%s\n' "${KUBECONFIG}"

echo
echo "Prerequisite check passed. Confirm your EC2 On-Demand G instance quota and ${GPU_INSTANCE_TYPE} capacity before continuing."
