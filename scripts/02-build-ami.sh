#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws packer jq; do
  require_tool "${tool}"
done
require_aws_identity

vpc_id="$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query 'cluster.resourcesVpcConfig.vpcId' \
  --output text)"

packer_subnet_id="${PACKER_SUBNET_ID:-}"
if [[ -z "${packer_subnet_id}" ]]; then
  packer_subnet_id="$(aws ec2 describe-subnets \
    --region "${AWS_REGION}" \
    --filters \
      "Name=vpc-id,Values=${vpc_id}" \
      'Name=tag:kubernetes.io/role/elb,Values=1' \
    --query 'Subnets | sort_by(@, &AvailabilityZone)[0].SubnetId' \
    --output text)"
fi

if [[ -z "${packer_subnet_id}" || "${packer_subnet_id}" == "None" ]]; then
  echo "No public subnet found in VPC ${vpc_id}. Set PACKER_SUBNET_ID to a public subnet with outbound internet access." >&2
  exit 1
fi

source_ami_id="${SOURCE_AMI_ID:-}"
if [[ -z "${source_ami_id}" ]]; then
  source_ami_id="$(aws ssm get-parameter \
    --name "/aws/service/eks/optimized-ami/${EKS_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
    --region "${AWS_REGION}" \
    --query 'Parameter.Value' \
    --output text)"
fi

printf '%s\n' "${source_ami_id}" >"${STATE_DIR}/source-ami-id"
printf '%s\n' "${packer_subnet_id}" >"${STATE_DIR}/packer-subnet-id"

echo "Building from ${source_ami_id} in subnet ${packer_subnet_id}."
packer init "${ROOT_DIR}/ami/eks-al2023-r615.pkr.hcl"
packer build \
  -var "aws_region=${AWS_REGION}" \
  -var "eks_version=${EKS_VERSION}" \
  -var "source_ami_id=${source_ami_id}" \
  -var "subnet_id=${packer_subnet_id}" \
  -var "nvidia_driver_version=${NVIDIA_DRIVER_VERSION}" \
  "${ROOT_DIR}/ami/eks-al2023-r615.pkr.hcl"

ami_id="$(jq -r '.builds[-1].artifact_id | split(":")[-1]' "${ROOT_DIR}/ami/manifest.json")"
if [[ ! "${ami_id}" =~ ^ami-[0-9a-f]+$ ]]; then
  echo "Packer manifest did not contain a valid AMI ID: ${ami_id}" >&2
  exit 1
fi

# install-r615.sh records the driver version actually installed from the
# CUDA repo (which can differ from the configured branch selector once the
# repo advances to a later point release) to /etc/eks-runai-nvidia-driver-
# version on the built instance. The Packer template downloads that file
# to ami/installed-driver-version.txt before the instance is imaged. Read
# it here, validate it, and store it keyed to this specific AMI ID so a
# later run with a different AMI can never silently reuse a stale value.
installed_version_file="${ROOT_DIR}/ami/installed-driver-version.txt"
if [[ ! -s "${installed_version_file}" ]]; then
  echo "Packer did not produce ${installed_version_file}; cannot determine the actual installed driver version." >&2
  exit 1
fi
installed_driver_version="$(<"${installed_version_file}")"
if [[ ! "${installed_driver_version}" =~ ^615\.[0-9]+\.[0-9]+$ ]]; then
  echo "Unexpected installed driver version read from ${installed_version_file}: '${installed_driver_version}'" >&2
  exit 1
fi
rm -f "${installed_version_file}"

aws ec2 wait image-available --region "${AWS_REGION}" --image-ids "${ami_id}"

# Packer tagged the AMI with the configured branch selector at build-start,
# before the actual point release was known. Overwrite that tag now with
# the version actually discovered on the image so the published AMI
# metadata never understates the real driver version.
aws ec2 create-tags \
  --region "${AWS_REGION}" \
  --resources "${ami_id}" \
  --tags "Key=nvidia-driver-version,Value=${installed_driver_version}"

printf '%s\n' "${ami_id}" >"${STATE_DIR}/ami-id"
printf '%s\n' "${installed_driver_version}" >"${STATE_DIR}/ami-id.${ami_id}.installed-driver-version"
printf '%s\n' "${installed_driver_version}" >"${STATE_DIR}/installed-driver-version"

echo "Requested branch ${NVIDIA_DRIVER_VERSION}; built AMI ${ami_id} has driver ${installed_driver_version}."

aws ec2 describe-images \
  --region "${AWS_REGION}" \
  --image-ids "${ami_id}" \
  --query 'Images[0].{ImageId:ImageId,Name:Name,State:State,CreationDate:CreationDate}' \
  --output table
