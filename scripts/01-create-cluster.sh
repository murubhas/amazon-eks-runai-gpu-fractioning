#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in aws eksctl kubectl; do
  require_tool "${tool}"
done
require_aws_identity

if cluster_description="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" 2>&1)"; then
  echo "EKS cluster ${CLUSTER_NAME} already exists; skipping creation."
elif [[ "${cluster_description}" == *ResourceNotFoundException* ]]; then
  public_access_cidrs="$(resolve_public_access_cidrs)"
  render_cluster_config "${public_access_cidrs}"
  echo "Public EKS API access is restricted to ${public_access_cidrs}; private endpoint access remains enabled."
  eksctl create cluster \
    --config-file "${STATE_DIR}/eksctl-cluster.yaml" \
    --kubeconfig "${KUBECONFIG}" \
    --set-kubeconfig-context=false \
    --timeout 60m \
    --color false
else
  echo "Cannot determine whether ${CLUSTER_NAME} exists; refusing creation: ${cluster_description}" >&2
  exit 1
fi

# Always (re)write the kubeconfig entry from the live cluster description,
# for BOTH the freshly-created and already-exists paths. The STATE_DIR
# kubeconfig is reused across runs, and `aws eks update-kubeconfig` keys its
# cluster entry by the cluster ARN, which is identical for every cluster of
# this name. A previous cluster of the same name therefore leaves a stale
# server endpoint behind in this file.
#
# `eksctl create cluster --set-kubeconfig-context=false` does NOT skip
# writing the kubeconfig entry -- it still writes a fresh cluster/context
# entry with the new cluster's current endpoint. What it skips is selecting
# that new context as current-context. If an older AWS-generated context
# (from a previous same-name cluster) was already selected, it stays
# selected, and `kube_context()` -- which reads current-context -- returns
# that stale selection, pointing kubectl at a torn-down endpoint that no
# longer resolves ("no such host"). The `aws eks update-kubeconfig` call
# below both refreshes the entry's endpoint and sets current-context, so the
# selected context can never be the stale one.
aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --kubeconfig "${KUBECONFIG}" \
  --alias "${CLUSTER_NAME}"

kubectl --kubeconfig "${KUBECONFIG}" config use-context "$(kube_context)" >/dev/null

# The cluster and its nodes are already confirmed ready above, and the
# kubeconfig now points at the current endpoint. A freshly-created endpoint's
# DNS record can still take a few seconds to become resolvable locally, which
# is a transient lookup failure rather than a problem with the cluster. Retry
# briefly instead of letting the whole script exit non-zero on a healthy
# cluster. (This retry does NOT paper over a stale/wrong endpoint — the
# update-kubeconfig refresh above guarantees the endpoint is correct first.)
run_kubectl_retry get nodes -o wide
