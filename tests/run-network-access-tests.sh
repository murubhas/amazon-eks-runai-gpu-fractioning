#!/usr/bin/env bash
# No AWS, Kubernetes, or network calls: exported functions replace every
# external service used by create-cluster, including public-IP discovery.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "${WORK_DIR}"' EXIT
pass_count=0
fail_count=0

aws() {
  printf 'aws %s\n' "$*" >>"${MOCK_CALL_LOG}"
  case "$1 $2" in
    "sts get-caller-identity") printf '{"Account":"123456789012"}\n' ;;
    "eks describe-cluster")
      case "${MOCK_CLUSTER_STATUS:-absent}" in
        exists) printf '{"cluster":{"name":"mock-cluster"}}\n' ;;
        absent) echo 'ResourceNotFoundException: No cluster found' >&2; return 254 ;;
        *) echo 'AccessDeniedException: not authorized' >&2; return 254 ;;
      esac
      ;;
    "eks update-kubeconfig") return 0 ;;
    *) echo "Unexpected AWS mock call: $*" >&2; return 99 ;;
  esac
}

eksctl() {
  printf 'eksctl %s\n' "$*" >>"${MOCK_CALL_LOG}"
  [[ "$1 $2" == "create cluster" ]]
}

kubectl() {
  printf 'kubectl %s\n' "$*" >>"${MOCK_CALL_LOG}"
  case "$*" in
    *"config current-context"*) printf 'mock-cluster\n' ;;
    *"config use-context"*|*"get nodes"*) return 0 ;;
    *) echo "Unexpected kubectl mock call: $*" >&2; return 99 ;;
  esac
}

curl() {
  printf 'curl %s\n' "$*" >>"${MOCK_CALL_LOG}"
  [[ "${MOCK_CHECKIP_FAIL:-false}" != true ]] || return 22
  printf '%s\n' "${MOCK_PUBLIC_IP:-198.51.100.24}"
}
export -f aws eksctl kubectl curl

run_create() {
  CASE_DIR="$(mktemp -d "${WORK_DIR}/case.XXXXXX")"
  export STATE_DIR="${CASE_DIR}/.state" MOCK_CALL_LOG="${CASE_DIR}/calls.log"
  : >"${MOCK_CALL_LOG}"
  if LAST_OUTPUT="$(bash "${ROOT_DIR}/scripts/01-create-cluster.sh" 2>&1)"; then
    LAST_STATUS=0
  else
    LAST_STATUS=$?
  fi
}

assert_status() {
  [[ "${LAST_STATUS}" -eq "$1" ]] || {
    printf 'Expected exit %s, got %s:\n%s\n' "$1" "${LAST_STATUS}" "${LAST_OUTPUT}" >&2
    return 1
  }
}

assert_call() {
  grep -Fq -- "$1" "${MOCK_CALL_LOG}"
}

assert_no_call() {
  ! grep -Fq -- "$1" "${MOCK_CALL_LOG}"
}

assert_config() {
  grep -Fxq -- "$1" "${STATE_DIR}/eksctl-cluster.yaml"
}

run_test() {
  local name="$1"
  shift
  unset EKS_PUBLIC_ACCESS_CIDRS MOCK_CHECKIP_FAIL MOCK_PUBLIC_IP MOCK_CLUSTER_STATUS
  export AWS_REGION=us-east-2 CLUSTER_NAME=mock-cluster
  if "$@"; then
    echo "PASS: ${name}"
    pass_count=$((pass_count + 1))
  else
    echo "FAIL: ${name}" >&2
    fail_count=$((fail_count + 1))
  fi
}

test_discovered_ip() {
  run_create
  assert_status 0 \
    && assert_config '  publicAccessCIDRs: ["198.51.100.24/32"]' \
    && assert_config '    privateAccess: true' \
    && assert_call 'https://checkip.amazonaws.com' \
    && assert_call 'eksctl create cluster'
}

test_explicit_cidrs() {
  export EKS_PUBLIC_ACCESS_CIDRS=198.51.100.24/32,203.0.113.0/24
  run_create
  assert_status 0 \
    && assert_config '  publicAccessCIDRs: ["198.51.100.24/32", "203.0.113.0/24"]' \
    && assert_no_call 'curl '
}

test_invalid_cidr() {
  export EKS_PUBLIC_ACCESS_CIDRS="$1"
  run_create
  assert_status 1 && assert_no_call 'eksctl create' && assert_no_call 'update-kubeconfig'
}

test_discovery_failure() {
  export MOCK_CHECKIP_FAIL=true
  run_create
  assert_status 1 && assert_no_call 'eksctl create' && assert_no_call 'update-kubeconfig'
}

test_invalid_discovered_ip() {
  export MOCK_PUBLIC_IP='<html>upstream error</html>'
  run_create
  assert_status 1 && assert_no_call 'eksctl create'
}

test_existing_cluster() {
  export MOCK_CLUSTER_STATUS=exists MOCK_CHECKIP_FAIL=true
  run_create
  assert_status 0 && assert_no_call 'curl ' && assert_no_call 'eksctl create' \
    && assert_call 'aws eks update-kubeconfig'
}

test_ambiguous_cluster_lookup() {
  export MOCK_CLUSTER_STATUS=access-denied
  run_create
  assert_status 1 && assert_no_call 'curl ' && assert_no_call 'eksctl create' \
    && assert_no_call 'update-kubeconfig'
}

test_region_setting() {
  export AWS_REGION=eu-west-1 EKS_PUBLIC_ACCESS_CIDRS=198.51.100.24/32
  run_create
  assert_status 0 && assert_config '  region: eu-west-1' \
    && assert_call '--region eu-west-1'
}

test_state_permissions() {
  run_create
  assert_status 0 \
    && [[ -z "$(find "${STATE_DIR}" -perm -004 -print)" ]] \
    && [[ -z "$(find "${STATE_DIR}" -perm -040 -print)" ]]
}

test_packer_ssh_restriction() {
  grep -Eq '^  temporary_security_group_source_public_ip *= true$' \
    "${ROOT_DIR}/ami/eks-al2023-r615.pkr.hcl"
}

run_test 'Discovered IPv4 /32 and private endpoint are rendered' test_discovered_ip
run_test 'Explicit trusted CIDRs do not call IP discovery' test_explicit_cidrs
run_test 'Unrestricted /0 access is refused' test_invalid_cidr '0.0.0.0/0'
run_test 'Out-of-range IPv4 octet is refused' test_invalid_cidr '999.1.2.3/32'
run_test 'Leading-zero IPv4 octet is refused' test_invalid_cidr '198.051.100.24/32'
run_test 'Out-of-range prefix is refused' test_invalid_cidr '198.51.100.24/33'
run_test 'IPv6 is refused by this IPv4 walkthrough' test_invalid_cidr '::/0'
run_test 'Trailing empty CIDR is refused' test_invalid_cidr '198.51.100.24/32,'
run_test 'Embedded empty CIDR is refused' test_invalid_cidr '198.51.100.24/32,,203.0.113.0/24'
run_test 'Newline injection is refused' test_invalid_cidr $'198.51.100.24/32\n  nat: {}'
run_test 'Failed discovery cannot create a cluster' test_discovery_failure
run_test 'Invalid discovery response cannot create a cluster' test_invalid_discovered_ip
run_test 'Existing cluster only refreshes kubeconfig' test_existing_cluster
run_test 'AccessDenied cannot trigger cluster creation' test_ambiguous_cluster_lookup
run_test 'Configured Region is preserved' test_region_setting
run_test 'New state files are not group/world readable' test_state_permissions
run_test 'Packer SSH is limited to the builder operator IP' test_packer_ssh_restriction

printf '\n%d passed; %d failed\n' "${pass_count}" "${fail_count}"
[[ "${fail_count}" -eq 0 ]]
