#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl; do
  require_tool "${tool}"
done
require_aws_identity

ami_id="${AMI_ID:-}"
if [[ -z "${ami_id}" && -f "${STATE_DIR}/ami-id" ]]; then
  ami_id="$(<"${STATE_DIR}/ami-id")"
fi
if [[ ! "${ami_id}" =~ ^ami-[0-9a-f]+$ ]]; then
  echo "Set AMI_ID or run scripts/02-build-ami.sh first." >&2
  exit 1
fi

render_gpu_nodegroup_config "${ami_id}"

if aws eks describe-nodegroup \
  --cluster-name "${CLUSTER_NAME}" \
  --nodegroup-name gpu-g5-r615-ondemand \
  --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "GPU node group already exists; skipping creation."
else
  eksctl create nodegroup \
    --config-file "${STATE_DIR}/eksctl-gpu-nodegroup.yaml" \
    --install-nvidia-plugin=false \
    --timeout 45m \
    --color false
fi

run_kubectl wait \
  --for=condition=Ready \
  node \
  --selector workload=runai-fractioning \
  --timeout=20m
run_kubectl get nodes --selector workload=runai-fractioning -o wide
