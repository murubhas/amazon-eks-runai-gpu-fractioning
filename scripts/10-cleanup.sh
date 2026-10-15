#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl helm; do
  require_tool "${tool}"
done
require_aws_identity

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
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

  eksctl delete cluster \
    --name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --wait \
    --color false
else
  echo "EKS cluster ${CLUSTER_NAME} is already absent."
fi

if aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  echo "Cluster cleanup verification failed: ${CLUSTER_NAME} still exists." >&2
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
