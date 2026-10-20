#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl helm; do
  require_tool "${tool}"
done
require_aws_identity

# eksctl names the control-plane CloudFormation stack "eksctl-<cluster>-cluster".
cluster_stack_name="eksctl-${CLUSTER_NAME}-cluster"

stack_status() {
  aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${cluster_stack_name}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>/dev/null || true
}

# Deletes the orphaned EKS-managed cluster security group that eksctl's
# CloudFormation stack does not own (see the comment above the retry logic
# below), then retries deletion of the verified, sample-owned CloudFormation
# stack directly -- NOT `eksctl delete cluster`, which re-runs DescribeCluster
# first and errors out ("ResourceNotFoundException: No cluster found") once
# the EKS control plane is already gone, even though the CloudFormation stack
# that still owns the VPC/networking is not. Re-running the removed-cluster
# command cannot recover a DELETE_FAILED stack.
recover_stack_deletion() {
  local vpc_id="$1"
  local sg_id="$2"

  if [[ -n "${sg_id}" && "${sg_id}" != "None" ]]; then
    echo "Checking whether security group ${sg_id} still has attached network interfaces." >&2
    local enis
    enis="$(aws ec2 describe-network-interfaces \
      --region "${AWS_REGION}" \
      --filters "Name=group-id,Values=${sg_id}" \
      --query 'NetworkInterfaces[].NetworkInterfaceId' \
      --output text)"
    if [[ -n "${enis}" && "${enis}" != "None" ]]; then
      echo "Security group ${sg_id} still has attached network interfaces (${enis});" >&2
      echo "these must detach (EKS control-plane teardown finishing, or an in-use ENI" >&2
      echo "from another resource) before the group can be deleted. Not retrying." >&2
      return 1
    fi

    echo "Verifying ${sg_id} is the expected EKS-managed cluster security group in VPC ${vpc_id}." >&2
    local sg_vpc group_name
    sg_vpc="$(aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --group-ids "${sg_id}" \
      --query 'SecurityGroups[0].VpcId' \
      --output text)"
    group_name="$(aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --group-ids "${sg_id}" \
      --query 'SecurityGroups[0].GroupName' \
      --output text)"
    if [[ "${sg_vpc}" != "${vpc_id}" ]]; then
      echo "Refusing to delete ${sg_id}: it belongs to VPC ${sg_vpc}, not the cluster's VPC ${vpc_id}." >&2
      return 1
    fi
    if [[ "${group_name}" != eks-cluster-sg-"${CLUSTER_NAME}"-* ]]; then
      echo "Refusing to delete ${sg_id}: group name '${group_name}' does not match the expected EKS-managed cluster security group pattern." >&2
      return 1
    fi

    echo "Deleting orphaned EKS cluster security group ${sg_id} (${group_name})." >&2
    aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg_id}"
  fi

  echo "Retrying deletion of CloudFormation stack ${cluster_stack_name}." >&2
  aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${cluster_stack_name}"
  aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${cluster_stack_name}"
}

cluster_exists=false
if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  cluster_exists=true

  project_tag="$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.tags.project' \
    --output text)"
  purpose_tag="$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.tags.purpose' \
    --output text)"
  if [[ "${project_tag}" != "amazon-eks-runai-gpu-fractioning" || \
        "${purpose_tag}" != "disposable-sample-validation" ]]; then
    echo "Refusing to delete cluster ${CLUSTER_NAME}: expected sample ownership tags were not found." >&2
    exit 1
  fi

  aws eks update-kubeconfig \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --kubeconfig "${KUBECONFIG}" \
    --alias "${CLUSTER_NAME}"

  # Record the cluster's VPC and EKS-managed cluster security group before
  # deletion. `clusterSecurityGroupId` is the authoritative identifier for
  # the orphan this cleanup may need to remove below -- read directly from
  # the API rather than inferred later from a name-pattern search. The
  # describe-cluster call must SUCCEED here (the cluster was just confirmed to
  # exist above), so a lookup error is surfaced rather than suppressed with
  # `|| true`; only a genuinely empty/None field is tolerated. A missing VPC or
  # security-group id would leave the recovery step unable to identify the
  # orphan, so refuse rather than guess.
  if ! cluster_describe="$(aws eks describe-cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --query 'cluster.resourcesVpcConfig.[vpcId,clusterSecurityGroupId]' \
    --output text)"; then
    echo "Failed to describe cluster ${CLUSTER_NAME} to record its VPC and security group before deletion." >&2
    exit 1
  fi
  cluster_vpc_id="$(printf '%s' "${cluster_describe}" | awk '{print $1}')"
  cluster_sg_id="$(printf '%s' "${cluster_describe}" | awk '{print $2}')"

  run_kubectl delete namespace runai-fractioning-test --ignore-not-found --wait=true

  if helm status kai-scheduler --namespace kai-scheduler --kubeconfig "${KUBECONFIG}" --kube-context "$(kube_context)" >/dev/null 2>&1; then
    helm uninstall kai-scheduler \
      --namespace kai-scheduler \
      --kubeconfig "${KUBECONFIG}" \
      --kube-context "$(kube_context)" \
      --wait \
      --timeout 10m
  fi

  if helm status gpu-operator --namespace gpu-operator --kubeconfig "${KUBECONFIG}" --kube-context "$(kube_context)" >/dev/null 2>&1; then
    helm uninstall gpu-operator \
      --namespace gpu-operator \
      --kubeconfig "${KUBECONFIG}" \
      --kube-context "$(kube_context)" \
      --wait \
      --timeout 10m
  fi

  # eksctl delete cluster can fail at VPC deletion because EKS auto-creates a
  # cluster security group (resourcesVpcConfig.clusterSecurityGroupId) that is
  # NOT part of the eksctl CloudFormation stack. CloudFormation cannot delete
  # that group, so the VPC is left with a dependency and the stack ends in
  # DELETE_FAILED. `eksctl delete cluster` may have already deleted the EKS
  # control plane itself before failing on the stack, so a failure here does
  # NOT necessarily mean the cluster is still there -- recover_stack_deletion
  # operates on the CloudFormation stack directly rather than re-invoking
  # `eksctl delete cluster`, which would re-run DescribeCluster and fail with
  # "no cluster found" against an already-deleted control plane.
  if ! eksctl delete cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --wait \
    --color false; then
    echo "First cluster deletion attempt failed; attempting recovery." >&2
    recover_stack_deletion "${cluster_vpc_id}" "${cluster_sg_id}"
  fi
else
  echo "EKS cluster ${CLUSTER_NAME} is already absent."
fi

# Recover a cleanup that was interrupted after the EKS control plane was
# deleted but before its CloudFormation stack finished tearing down (for
# example, a previous run exited after the orphan-security-group failure
# above, or was interrupted mid-recovery). Checking only "does the EKS
# cluster exist" skips this case and can let `run.sh cleanup` print success
# while the stack, VPC, and its networking resources are still live.
if [[ "${cluster_exists}" == "false" ]]; then
  existing_status="$(stack_status)"
  if [[ -n "${existing_status}" && "${existing_status}" != "DELETE_COMPLETE" ]]; then
    echo "CloudFormation stack ${cluster_stack_name} is in state ${existing_status} with no EKS cluster present; recovering." >&2
    # The cluster API is gone, so clusterSecurityGroupId can no longer be read
    # directly; derive the VPC from the stack's own output and the orphaned
    # security group by the EKS-managed name pattern within that VPC. Both
    # lookups must SUCCEED (the stack was just confirmed present); a call
    # failure is surfaced rather than suppressed with `|| true`. An empty
    # result is tolerated and handled explicitly below.
    if ! stack_vpc_id="$(aws cloudformation describe-stacks \
      --region "${AWS_REGION}" \
      --stack-name "${cluster_stack_name}" \
      --query "Stacks[0].Outputs[?OutputKey=='VPC'].OutputValue | [0]" \
      --output text)"; then
      echo "Failed to read the VPC output from CloudFormation stack ${cluster_stack_name} during recovery." >&2
      exit 1
    fi
    stale_sg_id=""
    if [[ -n "${stack_vpc_id}" && "${stack_vpc_id}" != "None" ]]; then
      if ! stale_sg_id="$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --filters \
          "Name=vpc-id,Values=${stack_vpc_id}" \
          "Name=group-name,Values=eks-cluster-sg-${CLUSTER_NAME}-*" \
        --query 'SecurityGroups[0].GroupId' \
        --output text)"; then
        echo "Failed to look up the orphaned EKS cluster security group in VPC ${stack_vpc_id} during recovery." >&2
        exit 1
      fi
    fi
    recover_stack_deletion "${stack_vpc_id}" "${stale_sg_id}"
  fi
fi

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Cluster cleanup verification failed: ${CLUSTER_NAME} still exists." >&2
  exit 1
fi

final_status="$(stack_status)"
if [[ -n "${final_status}" && "${final_status}" != "DELETE_COMPLETE" ]]; then
  echo "Cluster cleanup verification failed: CloudFormation stack ${cluster_stack_name} is in state ${final_status}, not DELETE_COMPLETE." >&2
  exit 1
fi

echo "Disposable EKS resources were removed."
echo "The custom AMI and its EBS snapshot were preserved. Set DELETE_CUSTOM_AMI=true only when you intend to remove them."

if [[ "${DELETE_CUSTOM_AMI:-false}" == "true" ]]; then
  ami_id="${AMI_ID:-}"
  if [[ -z "${ami_id}" && -f "${STATE_DIR}/ami-id" ]]; then
    ami_id="$(<"${STATE_DIR}/ami-id")"
  fi
  if [[ ! "${ami_id}" =~ ^ami-[0-9a-f]+$ ]]; then
    echo "A valid AMI_ID is required when DELETE_CUSTOM_AMI=true." >&2
    exit 1
  fi

  ami_purpose="$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --image-ids "${ami_id}" \
    --query 'Images[0].Tags[?Key==`purpose`].Value | [0]' \
    --output text)"
  if [[ "${ami_purpose}" != "runai-gpu-fractioning-sample" ]]; then
    echo "Refusing to deregister ${ami_id}: expected sample ownership tag was not found." >&2
    exit 1
  fi

  snapshot_ids="$(aws ec2 describe-images \
    --region "${AWS_REGION}" \
    --image-ids "${ami_id}" \
    --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' \
    --output text)"
  aws ec2 deregister-image --region "${AWS_REGION}" --image-id "${ami_id}"
  for snapshot_id in ${snapshot_ids}; do
    aws ec2 delete-snapshot --region "${AWS_REGION}" --snapshot-id "${snapshot_id}"
  done
  echo "Removed custom AMI ${ami_id} and snapshots: ${snapshot_ids}"
fi
