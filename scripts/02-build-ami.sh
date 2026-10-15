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

aws ec2 wait image-available --region "${AWS_REGION}" --image-ids "${ami_id}"
printf '%s\n' "${ami_id}" >"${STATE_DIR}/ami-id"

aws ec2 describe-images \
  --region "${AWS_REGION}" \
  --image-ids "${ami_id}" \
  --query 'Images[0].{ImageId:ImageId,Name:Name,State:State,CreationDate:CreationDate}' \
  --output table
