#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in kubectl helm; do
  require_tool "${tool}"
done

run_kubectl apply -f "${ROOT_DIR}/kubernetes/platform-namespaces.yaml"

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update
helm repo update nvidia

helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --version "${GPU_OPERATOR_VERSION}" \
  --values "${ROOT_DIR}/helm/gpu-operator-values.yaml" \
  --kubeconfig "${KUBECONFIG}" \
  --kube-context "$(kube_context)" \
  --wait \
  --wait-for-jobs \
  --timeout 20m \
  "$(helm_rollback_flag)"

for attempt in {1..60}; do
  state="$(run_kubectl get clusterpolicy cluster-policy -o jsonpath='{.status.state}' 2>/dev/null || true)"
  if [[ "${state}" == "ready" ]]; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    echo "GPU Operator ClusterPolicy did not become ready." >&2
    exit 1
  fi
  sleep 10
done

run_kubectl apply -f "${ROOT_DIR}/kubernetes/host-stack-inspection.yaml"
run_kubectl -n gpu-operator wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/host-stack-inspection \
  --timeout=10m
run_kubectl -n gpu-operator logs host-stack-inspection
run_kubectl -n gpu-operator delete pod host-stack-inspection --wait=true
