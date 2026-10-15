#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in kubectl helm jq; do
  require_tool "${tool}"
done

helm upgrade --install kai-scheduler \
  oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --namespace kai-scheduler \
  --version "${KAI_VERSION}" \
  --values "${ROOT_DIR}/helm/kai-values.yaml" \
  --kubeconfig "${KUBECONFIG}" \
  --kube-context "$(kube_context)" \
  --wait \
  --wait-for-jobs \
  --timeout 20m \
  "$(helm_rollback_flag)"

run_kubectl wait \
  --for=condition=Ready \
  gpufractioningconfig/default \
  --timeout=10m

for attempt in {1..60}; do
  nodes_json="$(run_kubectl get nodes -l workload=runai-fractioning -o json)"
  if jq -e '.items[].status.conditions[] | select(.type == "gpu-fractioning.nvidia.com/Ready" and .status == "True")' \
    <<<"${nodes_json}" >/dev/null; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    echo "GPU fractioning node condition did not become ready." >&2
    exit 1
  fi
  sleep 10
done

run_kubectl get gpufractioningconfig/default -o wide
run_kubectl get nodes -l workload=runai-fractioning -o wide
