#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${RUNAI_CONFIG_FILE:-${ROOT_DIR}/walkthrough.env}"

if [[ -f "${CONFIG_FILE}" ]]; then
  set -a
  source "${CONFIG_FILE}"
  set +a
fi

usage() {
  cat <<'EOF'
Usage: ./run.sh <command>

Commands:
  check                 Verify local tools and AWS identity
  create-cluster        Create the disposable EKS cluster
  build-ami             Build the custom AL2023 R615 AMI
  add-gpu-node          Add one On-Demand g5.xlarge node
  install-gpu-operator  Install GPU Operator and inspect the host stack
  baseline              Prove the default whole-GPU scheduling behavior
  install-kai           Install KAI Scheduler and GPU Fractioning
  share                 Run the positive two-Pod sharing test
  metrics               Show per-Pod GPU-memory metrics
  limit                 Prove rejection above the memory limit
  walkthrough           Run check through limit in order
  cleanup               Delete the cluster and preserve the custom AMI
  cleanup-all           Delete the cluster, custom AMI, and AMI snapshots
  help                  Show this message

Configuration is read from walkthrough.env by default. Set RUNAI_CONFIG_FILE
to use a different file. Cleanup refuses to delete resources without the
sample ownership tags.
EOF
}

run_step() {
  local script="$1"
  printf '\n==> %s\n' "${script}"
  "${ROOT_DIR}/scripts/${script}"
}

command="${1:-help}"
case "${command}" in
  check) run_step 00-check-prerequisites.sh ;;
  create-cluster) run_step 01-create-cluster.sh ;;
  build-ami) run_step 02-build-ami.sh ;;
  add-gpu-node) run_step 03-add-gpu-node.sh ;;
  install-gpu-operator) run_step 04-install-gpu-operator.sh ;;
  baseline) run_step 05-test-whole-gpu.sh ;;
  install-kai) run_step 06-install-kai.sh ;;
  share) run_step 07-test-fractioning.sh ;;
  metrics) run_step 08-show-metrics.sh ;;
  limit) run_step 09-test-memory-limit.sh ;;
  walkthrough|all)
    for script in \
      00-check-prerequisites.sh \
      01-create-cluster.sh \
      02-build-ami.sh \
      03-add-gpu-node.sh \
      04-install-gpu-operator.sh \
      05-test-whole-gpu.sh \
      06-install-kai.sh \
      07-test-fractioning.sh \
      08-show-metrics.sh \
      09-test-memory-limit.sh; do
      run_step "${script}"
    done
    ;;
  cleanup) run_step 10-cleanup.sh ;;
  cleanup-all)
    export DELETE_CUSTOM_AMI=true
    run_step 10-cleanup.sh
    ;;
  help|-h|--help) usage ;;
  *)
    echo "Unknown command: ${command}" >&2
    usage >&2
    exit 2
    ;;
esac
