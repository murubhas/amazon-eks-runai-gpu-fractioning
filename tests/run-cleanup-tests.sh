#!/usr/bin/env bash
# Regression tests for scripts/10-cleanup.sh's safety-critical decision
# logic, covering the four cleanup-recovery findings from PR #1 review
# (murubhas, 2026-10-20) plus the SG prefix-collision case it asked be
# covered alongside them. No real AWS calls are made: tests/mocks/{aws,
# eksctl,kubectl,helm} are prepended to PATH and driven entirely by MOCK_*
# environment variables (see tests/mocks/aws for the scenarios it supports).
#
# Each test asserts both the script's exit code AND, since the exit code
# alone can't tell a safe refusal apart from a bug that happens to also
# exit nonzero, whether a destructive call (delete-stack /
# delete-security-group) was actually issued -- recorded in MOCK_CALL_LOG
# regardless of why the mock was called.
#
# Usage: tests/run-cleanup-tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
CLEANUP_SCRIPT="${ROOT_DIR}/scripts/10-cleanup.sh"

pass_count=0
fail_count=0

# Runs scripts/10-cleanup.sh under the mocked tools with the given MOCK_*
# env already exported by the caller, then clears those MOCK_* exports so
# each test starts from a clean slate. Captures exit code, stdout+stderr,
# and the destructive-call log for the caller's assertions.
run_cleanup() {
  local work_dir
  work_dir="$(mktemp -d)"
  export MOCK_CALL_LOG="${work_dir}/calls.log"
  touch "${MOCK_CALL_LOG}"
  export MOCK_STACK_DELETED_FLAG="${work_dir}/stack-deleted.flag"
  export MOCK_CLUSTER_DELETED_FLAG="${work_dir}/cluster-deleted.flag"
  export STATE_DIR="${work_dir}/.state"
  export CLUSTER_NAME="${CLUSTER_NAME:-mock-cluster}"
  export AWS_REGION="${AWS_REGION:-us-east-2}"

  set +e
  LAST_OUTPUT="$(PATH="${TESTS_DIR}/mocks:${PATH}" bash "${CLEANUP_SCRIPT}" 2>&1)"
  LAST_EXIT_CODE=$?
  set -e

  LAST_CALL_LOG="$(cat "${MOCK_CALL_LOG}")"
  rm -rf "${work_dir}"
}

assert_exit_code() {
  local expected="$1" label="$2"
  if [[ "${LAST_EXIT_CODE}" -eq "${expected}" ]]; then
    return 0
  fi
  echo "    FAIL (${label}): expected exit code ${expected}, got ${LAST_EXIT_CODE}" >&2
  echo "    --- output ---" >&2
  echo "${LAST_OUTPUT}" | sed 's/^/    /' >&2
  return 1
}

assert_call_made() {
  local pattern="$1" label="$2"
  if printf '%s\n' "${LAST_CALL_LOG}" | grep -q -- "${pattern}"; then
    return 0
  fi
  echo "    FAIL (${label}): expected a call matching '${pattern}', none found" >&2
  echo "    --- call log ---" >&2
  echo "${LAST_CALL_LOG}" | sed 's/^/    /' >&2
  return 1
}

assert_call_not_made() {
  local pattern="$1" label="$2"
  if ! printf '%s\n' "${LAST_CALL_LOG}" | grep -q -- "${pattern}"; then
    return 0
  fi
  echo "    FAIL (${label}): expected no call matching '${pattern}', but found one" >&2
  echo "    --- call log ---" >&2
  echo "${LAST_CALL_LOG}" | sed 's/^/    /' >&2
  return 1
}

run_test() {
  local name="$1"
  shift
  echo "RUNNING: ${name}"
  unset MOCK_DESCRIBE_CLUSTER MOCK_STACK MOCK_STACK_STATUS MOCK_STACK_PROJECT_TAG \
    MOCK_STACK_PURPOSE_TAG MOCK_STACK_VPC_OUTPUT MOCK_SG_ENIS MOCK_SG_VPC_ID \
    MOCK_SG_GROUP_NAME MOCK_SG_CLUSTER_TAG MOCK_SG_FILTER_RESULT \
    MOCK_CLUSTER_PROJECT_TAG MOCK_CLUSTER_PURPOSE_TAG MOCK_CLUSTER_VPC_ID \
    MOCK_CLUSTER_SG_ID MOCK_EKSCTL_DELETE_CLUSTER_SUCCEEDS CLUSTER_NAME AWS_REGION
  if "$@"; then
    echo "  PASS: ${name}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${name}"
    fail_count=$((fail_count + 1))
  fi
}

# --- Comment 2 (P1, line ~173): do not treat a failed DescribeCluster as
# confirmed absence. AccessDenied must refuse, not route into the
# direct-stack-deletion recovery path. ---
test_access_denied_describe_cluster_refuses() {
  export MOCK_DESCRIBE_CLUSTER=access-denied
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=CREATE_COMPLETE
  run_cleanup
  assert_exit_code 1 "AccessDenied on describe-cluster must exit nonzero" \
    && assert_call_not_made "delete-stack" "AccessDenied must not trigger delete-stack" \
    && assert_call_not_made "delete-security-group" "AccessDenied must not trigger delete-security-group"
}

# --- Comment 1 (P1, line ~19): do not treat every describe-stacks error as
# "stack absent". AccessDenied there must also refuse, not report success. ---
test_access_denied_describe_stacks_refuses() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=access-denied
  run_cleanup
  assert_exit_code 1 "AccessDenied on describe-stacks must exit nonzero, not report success" \
    && assert_call_not_made "delete-stack" "AccessDenied on describe-stacks must not trigger delete-stack"
}

# --- Comment 3 (P1, line ~204): verify sample ownership before recovering
# an absent cluster. A present, non-DELETE_COMPLETE stack with the wrong
# ownership tags must be refused, not deleted by name alone. ---
test_unowned_stack_recovery_refused() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=DELETE_FAILED
  export MOCK_STACK_PROJECT_TAG=some-other-project
  export MOCK_STACK_PURPOSE_TAG=some-other-purpose
  run_cleanup
  assert_exit_code 1 "unowned DELETE_FAILED stack must be refused" \
    && assert_call_not_made "delete-stack" "unowned stack must not be deleted" \
    && assert_call_not_made "delete-security-group" "unowned stack's SG must not be deleted"
}

# --- Same as above, but ownership tags are missing entirely (empty/None)
# rather than merely different -- the "missing" half of "missing/mismatched
# tags" from comment 3. ---
test_missing_ownership_tags_recovery_refused() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=DELETE_FAILED
  export MOCK_STACK_PROJECT_TAG=None
  export MOCK_STACK_PURPOSE_TAG=None
  run_cleanup
  assert_exit_code 1 "DELETE_FAILED stack with missing ownership tags must be refused" \
    && assert_call_not_made "delete-stack" "stack with missing tags must not be deleted"
}

# --- Positive control for comment 3: a correctly-owned, interrupted
# DELETE_FAILED stack with no orphan SG left SHOULD be recovered. Confirms
# the ownership check doesn't block the legitimate case it's meant to allow. ---
test_owned_stack_recovery_proceeds() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=DELETE_FAILED
  export MOCK_STACK_PROJECT_TAG=amazon-eks-runai-gpu-fractioning
  export MOCK_STACK_PURPOSE_TAG=disposable-sample-validation
  export MOCK_STACK_VPC_OUTPUT=vpc-bbb222
  export MOCK_SG_FILTER_RESULT=""
  run_cleanup
  assert_exit_code 0 "owned, interrupted DELETE_FAILED stack with no orphan SG should recover" \
    && assert_call_made "delete-stack" "owned stack recovery should retry delete-stack"
}

# --- Comment 4 (P2, line ~198) / SG prefix-collision: an exact
# aws:eks:cluster-name tag match of a single orphan SG should be deleted, but
# if the lookup somehow returns more than one match (ambiguous), cleanup must
# refuse rather than guess via [0]. ---
test_sg_prefix_collision_refused() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=DELETE_FAILED
  export MOCK_STACK_PROJECT_TAG=amazon-eks-runai-gpu-fractioning
  export MOCK_STACK_PURPOSE_TAG=disposable-sample-validation
  export MOCK_STACK_VPC_OUTPUT=vpc-bbb222
  # Two groups match the tag filter -- ambiguous; must refuse, not pick [0].
  export MOCK_SG_FILTER_RESULT="sg-aaa111	sg-ccc333"
  run_cleanup
  assert_exit_code 1 "ambiguous (multiple) SG tag match must be refused" \
    && assert_call_not_made "delete-security-group" "ambiguous SG match must not be deleted" \
    && assert_call_not_made "delete-stack" "ambiguous SG match must not proceed to stack deletion"
}

# --- Comment 4 positive control: exactly one SG matches the exact tag ->
# recovery should proceed and delete that one SG. ---
test_sg_exact_tag_match_recovers() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=present
  export MOCK_STACK_STATUS=DELETE_FAILED
  export MOCK_STACK_PROJECT_TAG=amazon-eks-runai-gpu-fractioning
  export MOCK_STACK_PURPOSE_TAG=disposable-sample-validation
  export MOCK_STACK_VPC_OUTPUT=vpc-bbb222
  export MOCK_SG_FILTER_RESULT="sg-aaa111"
  export MOCK_SG_VPC_ID="vpc-bbb222"
  export MOCK_SG_CLUSTER_TAG="mock-cluster"
  export MOCK_SG_ENIS=""
  run_cleanup
  assert_exit_code 0 "single exact-tag SG match should recover cleanly" \
    && assert_call_made "delete-security-group" "single exact-tag SG match should be deleted" \
    && assert_call_made "delete-stack" "recovery should retry stack deletion after SG removal"
}

# --- Baseline: cluster absent, no stack present -> clean no-op success. ---
test_already_clean_reports_success() {
  export MOCK_DESCRIBE_CLUSTER=not-found
  export MOCK_STACK=absent
  run_cleanup
  assert_exit_code 0 "already-clean environment should report success" \
    && assert_call_not_made "delete-stack" "nothing to delete when already clean" \
    && assert_call_not_made "delete-security-group" "nothing to delete when already clean"
}

run_test "AccessDenied on describe-cluster refuses (comment 2, P1)" test_access_denied_describe_cluster_refuses
run_test "AccessDenied on describe-stacks refuses (comment 1, P1)" test_access_denied_describe_stacks_refuses
run_test "Unowned DELETE_FAILED stack recovery refused (comment 3, P1)" test_unowned_stack_recovery_refused
run_test "Missing ownership tags recovery refused (comment 3, P1)" test_missing_ownership_tags_recovery_refused
run_test "Owned DELETE_FAILED stack recovery proceeds (comment 3 control)" test_owned_stack_recovery_proceeds
run_test "SG prefix-collision (ambiguous tag match) refused (comment 4, P2)" test_sg_prefix_collision_refused
run_test "Single exact-tag SG match recovers (comment 4 control)" test_sg_exact_tag_match_recovers
run_test "Already-clean environment reports success (baseline)" test_already_clean_reports_success

# --- Sanity check: the main happy path (cluster exists, correctly owned,
# eksctl delete succeeds outright, no recovery needed) must still work after
# switching cluster-presence detection to describe_cluster_presence(). ---
test_normal_cluster_delete_succeeds() {
  export MOCK_DESCRIBE_CLUSTER=exists
  export MOCK_CLUSTER_PROJECT_TAG=amazon-eks-runai-gpu-fractioning
  export MOCK_CLUSTER_PURPOSE_TAG=disposable-sample-validation
  export MOCK_EKSCTL_DELETE_CLUSTER_SUCCEEDS=true
  export MOCK_STACK=absent
  run_cleanup
  assert_exit_code 0 "normal cluster deletion via eksctl should succeed without recovery" \
    && assert_call_not_made "delete-stack" "no direct stack deletion needed when eksctl succeeds outright" \
    && assert_call_not_made "delete-security-group" "no SG recovery needed when eksctl succeeds outright"
}
run_test "Normal cluster delete via eksctl succeeds (happy-path sanity)" test_normal_cluster_delete_succeeds

# --- Sanity check: an incorrectly-tagged, still-existing cluster must still
# be refused by the pre-existing ownership check (unrelated to this PR's
# fixes, but exercised by the same describe_cluster_presence() path). ---
test_existing_cluster_wrong_tags_refused() {
  export MOCK_DESCRIBE_CLUSTER=exists
  export MOCK_CLUSTER_PROJECT_TAG=some-other-project
  export MOCK_CLUSTER_PURPOSE_TAG=some-other-purpose
  run_cleanup
  assert_exit_code 1 "existing cluster with wrong ownership tags must be refused" \
    && assert_call_not_made "delete cluster" "unowned existing cluster must not be deleted"
}
run_test "Existing cluster with wrong ownership tags refused (pre-existing check sanity)" test_existing_cluster_wrong_tags_refused

echo
echo "=== ${pass_count} passed, ${fail_count} failed ==="
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
