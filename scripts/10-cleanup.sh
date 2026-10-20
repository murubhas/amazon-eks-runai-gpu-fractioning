#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl helm; do
  require_tool "${tool}"
done
require_aws_identity

# eksctl names the control-plane CloudFormation stack "eksctl-<cluster>-cluster".
cluster_stack_name="eksctl-${CLUSTER_NAME}-cluster"

# Ownership tags that eksctl's `metadata.tags` (config/eksctl-cluster.yaml.tpl)
# apply both to the EKS cluster resource AND, confirmed against eksctl's
# source (pkg/cfn/manager/api.go NewStackCollection/sharedTags), to the
# CloudFormation stack itself. The CFN-stack copy is what recovery paths
# below rely on once the EKS cluster API object is gone and can no longer be
# asked for its own tags.
expected_project_tag="amazon-eks-runai-gpu-fractioning"
expected_purpose_tag="disposable-sample-validation"

# Returns the stack's status via stdout, or an empty string if and only if
# AWS confirms the stack does not exist (the specific ValidationError
# `describe-stacks` returns for an unknown stack name). Any other failure
# (AccessDenied, expired credentials, throttling, a transport error) is a
# distinct, non-absence outcome and MUST NOT be collapsed into "no stack" --
# doing so would let a describe-stacks error masquerade as a clean stack-gone
# result and let the caller declare cleanup successful while the stack may
# still be fully present. Surfaces such errors by returning nonzero instead.
stack_status() {
  local output
  if output="$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${cluster_stack_name}" \
    --query 'Stacks[0].StackStatus' \
    --output text 2>&1)"; then
    printf '%s\n' "${output}"
    return 0
  fi
  if printf '%s' "${output}" | grep -q "does not exist"; then
    printf '\n'
    return 0
  fi
  echo "Failed to check status of CloudFormation stack ${cluster_stack_name}: ${output}" >&2
  return 1
}

# Verifies the CloudFormation stack carries this sample's ownership tags.
# Used by the interrupted-cleanup recovery path, where the EKS cluster API
# object is already gone and so can no longer be asked for its own tags --
# the stack's own Tags (set from the same `metadata.tags` at creation, see
# comment above) are the only ownership signal left. Exits nonzero (refusing
# recovery) on an unreadable tag or a mismatched/missing tag, rather than
# deleting a same-named stack that was never this sample's.
verify_stack_ownership() {
  local stack_name="$1"
  local project_tag purpose_tag
  if ! project_tag="$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Tags[?Key=='project'].Value | [0]" \
    --output text 2>&1)"; then
    echo "Failed to read ownership tags from CloudFormation stack ${stack_name}: ${project_tag}" >&2
    return 1
  fi
  if ! purpose_tag="$(aws cloudformation describe-stacks \
    --region "${AWS_REGION}" \
    --stack-name "${stack_name}" \
    --query "Stacks[0].Tags[?Key=='purpose'].Value | [0]" \
    --output text 2>&1)"; then
    echo "Failed to read ownership tags from CloudFormation stack ${stack_name}: ${purpose_tag}" >&2
    return 1
  fi
  if [[ "${project_tag}" != "${expected_project_tag}" || "${purpose_tag}" != "${expected_purpose_tag}" ]]; then
    echo "Refusing to recover stack ${stack_name}: expected sample ownership tags (project=${expected_project_tag}, purpose=${expected_purpose_tag}) were not found (got project=${project_tag}, purpose=${purpose_tag})." >&2
    return 1
  fi
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
    local sg_vpc sg_cluster_tag group_name
    sg_vpc="$(aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --group-ids "${sg_id}" \
      --query 'SecurityGroups[0].VpcId' \
      --output text)"
    sg_cluster_tag="$(aws ec2 describe-security-groups \
      --region "${AWS_REGION}" \
      --group-ids "${sg_id}" \
      --query "SecurityGroups[0].Tags[?Key=='aws:eks:cluster-name'].Value | [0]" \
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
    # Verify by the exact aws:eks:cluster-name tag EKS applies to this group
    # (see the lookup comment above for why a name-prefix match is
    # insufficient on its own) rather than a name-prefix glob.
    if [[ "${sg_cluster_tag}" != "${CLUSTER_NAME}" ]]; then
      echo "Refusing to delete ${sg_id}: aws:eks:cluster-name tag is '${sg_cluster_tag}', not the expected '${CLUSTER_NAME}'." >&2
      return 1
    fi

    echo "Deleting orphaned EKS cluster security group ${sg_id} (${group_name})." >&2
    aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg_id}"
  fi

  echo "Retrying deletion of CloudFormation stack ${cluster_stack_name}." >&2
  aws cloudformation delete-stack --region "${AWS_REGION}" --stack-name "${cluster_stack_name}"
  aws cloudformation wait stack-delete-complete --region "${AWS_REGION}" --stack-name "${cluster_stack_name}"
}

# Classifies a `describe-cluster` failure instead of collapsing every error
# into "cluster absent". Only the API's own confirmation that the cluster is
# gone (ResourceNotFoundException) means absent; AccessDenied, expired
# credentials, throttling, and transport errors are all distinct outcomes
# where the cluster's actual state is unknown, and MUST NOT be treated as
# absence -- doing so would route a potentially live cluster into the
# direct-stack-deletion recovery path below. Prints "true", "false", or
# "unknown" on stdout; the caller decides what to do with "unknown" (exit
# nonzero without deleting anything).
describe_cluster_presence() {
  local output
  if output="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>&1 >/dev/null)"; then
    printf 'true\n'
    return 0
  fi
  if printf '%s' "${output}" | grep -q "ResourceNotFoundException"; then
    printf 'false\n'
    return 0
  fi
  echo "Failed to determine whether cluster ${CLUSTER_NAME} exists: ${output}" >&2
  printf 'unknown\n'
  return 0
}

cluster_presence="$(describe_cluster_presence)"
if [[ "${cluster_presence}" == "unknown" ]]; then
  echo "Refusing to proceed: could not confirm whether cluster ${CLUSTER_NAME} exists (see error above). Not deleting anything." >&2
  exit 1
fi

cluster_exists=false
if [[ "${cluster_presence}" == "true" ]]; then
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
    # The EKS cluster is gone, so this branch cannot rely on the cluster-tags
    # check above (project_tag/purpose_tag, only run while describe-cluster
    # succeeds). CLUSTER_NAME is reader-supplied and could name a non-sample
    # eksctl stack whose control plane happens to already be gone; without
    # this check, recovery would delete that stack (and its SG/VPC) based on
    # name alone. Verify the CloudFormation stack's own ownership tags
    # (confirmed set from the same metadata.tags at creation -- see
    # expected_project_tag/expected_purpose_tag above) before any recovery
    # deletion, and refuse on a missing or mismatched tag.
    verify_stack_ownership "${cluster_stack_name}"
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
      # Select the orphaned EKS-managed cluster security group by the exact
      # `aws:eks:cluster-name` tag EKS applies to it (confirmed in AWS's EKS
      # security-group-requirements documentation), not by a
      # `eks-cluster-sg-${CLUSTER_NAME}-*` name-prefix filter. A prefix match
      # is ambiguous: for CLUSTER_NAME=demo, a leftover
      # eks-cluster-sg-demo-old-123 group from an unrelated prior cluster
      # also matches demo-*, and group-name filtering plus the VPC/name
      # checks in recover_stack_deletion would accept it. The tag is scoped
      # to exactly this cluster name, so it cannot collide that way. If more
      # than one group still matches (unexpected), refuse rather than guess
      # which one via [0].
      if ! stale_sg_matches="$(aws ec2 describe-security-groups \
        --region "${AWS_REGION}" \
        --filters \
          "Name=vpc-id,Values=${stack_vpc_id}" \
          "Name=tag:aws:eks:cluster-name,Values=${CLUSTER_NAME}" \
        --query 'SecurityGroups[].GroupId' \
        --output text)"; then
        echo "Failed to look up the orphaned EKS cluster security group in VPC ${stack_vpc_id} during recovery." >&2
        exit 1
      fi
      sg_match_count=0
      if [[ -n "${stale_sg_matches}" && "${stale_sg_matches}" != "None" ]]; then
        sg_match_count="$(printf '%s\n' "${stale_sg_matches}" | wc -w | tr -d ' ')"
      fi
      if (( sg_match_count > 1 )); then
        echo "Refusing recovery: found ${sg_match_count} security groups tagged aws:eks:cluster-name=${CLUSTER_NAME} in VPC ${stack_vpc_id} (${stale_sg_matches}); expected at most one." >&2
        exit 1
      fi
      if (( sg_match_count == 1 )); then
        stale_sg_id="${stale_sg_matches}"
      fi
    fi
    recover_stack_deletion "${stack_vpc_id}" "${stale_sg_id}"
  fi
fi

final_cluster_presence="$(describe_cluster_presence)"
if [[ "${final_cluster_presence}" != "false" ]]; then
  echo "Cluster cleanup verification failed: could not confirm ${CLUSTER_NAME} is absent (presence check returned '${final_cluster_presence}')." >&2
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
