#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in kubectl jq; do
  require_tool "${tool}"
done

run_kubectl apply -f "${ROOT_DIR}/kubernetes/test-namespace.yaml"
run_kubectl apply -f "${ROOT_DIR}/kubernetes/baseline-whole-gpu.yaml"

running=0
pending=0
for attempt in {1..60}; do
  pod_json="$(run_kubectl -n runai-fractioning-test get pods -l test=whole-gpu-baseline -o json)"
  running="$(jq '[.items[] | select(.status.phase == "Running")] | length' <<<"${pod_json}")"
  pending="$(jq '[.items[] | select(.status.phase == "Pending")] | length' <<<"${pod_json}")"
  if [[ "${running}" -eq 1 && "${pending}" -eq 1 ]]; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    echo "Timed out waiting for one Running and one Pending whole-GPU Pod." >&2
    break
  fi
  sleep 10
done

run_kubectl -n runai-fractioning-test get pods -o wide

if [[ "${running}" -ne 1 || "${pending}" -ne 1 ]]; then
  echo "Expected one Running and one Pending whole-GPU Pod; observed Running=${running}, Pending=${pending}." >&2
  run_kubectl -n runai-fractioning-test describe pods -l test=whole-gpu-baseline
  exit 1
fi

echo "Whole-GPU baseline passed: one Pod is Running and one is Pending."
run_kubectl delete -f "${ROOT_DIR}/kubernetes/baseline-whole-gpu.yaml" --wait=true
