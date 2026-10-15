#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

require_tool kubectl

run_kubectl apply -f "${ROOT_DIR}/kubernetes/cuda-memory-probe.yaml"
run_kubectl apply -f "${ROOT_DIR}/kubernetes/fraction-8gi-pods.yaml"

run_kubectl -n runai-fractioning-test wait \
  --for=condition=Ready \
  pod/fraction-8gi-a \
  pod/fraction-8gi-b \
  --timeout=10m

run_kubectl -n runai-fractioning-test get pods -o wide

log_a=""
log_b=""
for attempt in {1..60}; do
  log_a="$(run_kubectl -n runai-fractioning-test logs fraction-8gi-a)"
  log_b="$(run_kubectl -n runai-fractioning-test logs fraction-8gi-b)"
  if grep -q 'allocation_succeeded_mib=6144' <<<"${log_a}" && \
     grep -q 'allocation_succeeded_mib=6144' <<<"${log_b}"; then
    break
  fi
  if [[ "${attempt}" -eq 60 ]]; then
    echo "Timed out waiting for both 6 GiB allocations to succeed." >&2
    break
  fi
  sleep 5
done

printf '%s\n' "${log_a}"
printf '%s\n' "${log_b}"

node_a="$(run_kubectl -n runai-fractioning-test get pod fraction-8gi-a -o jsonpath='{.spec.nodeName}')"
node_b="$(run_kubectl -n runai-fractioning-test get pod fraction-8gi-b -o jsonpath='{.spec.nodeName}')"
uuid_a="$(awk -F, '/^GPU-/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}' <<<"${log_a}")"
uuid_b="$(awk -F, '/^GPU-/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); print $1; exit}' <<<"${log_b}")"

if [[ "${node_a}" != "${node_b}" || -z "${uuid_a}" || "${uuid_a}" != "${uuid_b}" ]]; then
  echo "Positive test failed: Pods did not report the same node and GPU UUID." >&2
  exit 1
fi
if ! grep -q 'allocation_succeeded_mib=6144' <<<"${log_a}" || \
   ! grep -q 'allocation_succeeded_mib=6144' <<<"${log_b}"; then
  echo "Positive test failed: one or both 6 GiB allocations did not succeed." >&2
  exit 1
fi

echo "Positive test passed: both 8 GiB contracts share node ${node_a} and GPU ${uuid_a}."
