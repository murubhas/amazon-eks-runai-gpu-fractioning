#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

for tool in kubectl jq curl; do
  require_tool "${tool}"
done

pods_json="$(run_kubectl -n kai-scheduler get pods -o json)"
metrics_pod="$(jq -r '.items[] | select(any(.spec.containers[]; .name == "metricsd")) | .metadata.name' <<<"${pods_json}" | head -n 1)"

if [[ -z "${metrics_pod}" ]]; then
  echo "No Pod with a metricsd container was found." >&2
  exit 1
fi

metrics_port="$(jq -r \
  --arg pod "${metrics_pod}" \
  '.items[] | select(.metadata.name == $pod) | .spec.containers[] | select(.name == "metricsd") | .ports[0].containerPort // 2112' \
  <<<"${pods_json}")"
local_port="${METRICS_LOCAL_PORT:-18080}"

run_kubectl -n kai-scheduler port-forward \
  "pod/${metrics_pod}" \
  "${local_port}:${metrics_port}" \
  >"${STATE_DIR}/metrics-port-forward.log" 2>&1 &
port_forward_pid=$!
trap 'kill "${port_forward_pid}" >/dev/null 2>&1 || true' EXIT

for attempt in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:${local_port}/metrics" >/dev/null; then
    break
  fi
  if [[ "${attempt}" -eq 30 ]]; then
    cat "${STATE_DIR}/metrics-port-forward.log" >&2
    exit 1
  fi
  sleep 1
done

curl --silent --fail "http://127.0.0.1:${local_port}/metrics" \
  | grep 'gpu_fractioning_gpu_memory_used_bytes' \
  | grep 'namespace="runai-fractioning-test"'
