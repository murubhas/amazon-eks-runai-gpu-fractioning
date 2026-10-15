#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_tool kubectl

run_kubectl -n runai-fractioning-test delete pod \
  fraction-8gi-a \
  fraction-8gi-b \
  --ignore-not-found \
  --wait=true
run_kubectl apply -f "${ROOT_DIR}/kubernetes/cuda-memory-probe.yaml"
run_kubectl apply -f "${ROOT_DIR}/kubernetes/fraction-8gi-negative.yaml"

run_kubectl -n runai-fractioning-test wait \
  --for=jsonpath='{.status.phase}'=Succeeded \
  pod/fraction-8gi-over-limit \
  --timeout=10m

run_kubectl -n runai-fractioning-test get pod fraction-8gi-over-limit -o wide

result="$(run_kubectl -n runai-fractioning-test logs fraction-8gi-over-limit)"
printf '%s\n' "${result}"

if ! grep -q 'allocation_failed=out of memory' <<<"${result}"; then
  echo "Negative test failed: the 9 GiB allocation was not rejected as expected." >&2
  exit 1
fi

echo "Negative test passed: the 8 GiB contract rejected a 9 GiB allocation."
