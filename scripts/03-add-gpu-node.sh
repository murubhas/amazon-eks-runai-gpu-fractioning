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

# Require the driver version actually discovered when this AMI was built
# (scripts/02-build-ami.sh), keyed to this exact AMI ID -- never fall back
# to the configured NVIDIA_DRIVER_VERSION env var, which only reflects the
# requested R615 branch and silently mislabels the node group if the repo
# installed a later point release. This also prevents reusing a stale
# recorded version left over from building a *different* AMI: if AMI_ID is
# overridden to something scripts/02-build-ami.sh did not just produce,
# the keyed file for that specific AMI ID must exist.
installed_version_file="${STATE_DIR}/ami-id.${ami_id}.installed-driver-version"
if [[ ! -s "${installed_version_file}" ]]; then
  echo "No recorded installed driver version for ${ami_id} at ${installed_version_file}." >&2
  echo "Run scripts/02-build-ami.sh to build (and record the version for) this AMI, or set AMI_ID to an AMI it built." >&2
  exit 1
fi
installed_driver_version="$(<"${installed_version_file}")"
if [[ ! "${installed_driver_version}" =~ ^615\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected installed driver version recorded for ${ami_id}: '${installed_driver_version}'" >&2
  exit 1
fi
echo "Using AMI ${ami_id} with recorded driver version ${installed_driver_version}."

render_gpu_nodegroup_config "${ami_id}" "${installed_driver_version}"

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
