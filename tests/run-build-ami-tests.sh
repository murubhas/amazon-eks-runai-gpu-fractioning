#!/usr/bin/env bash
# Regression tests for the NVIDIA driver-version metadata propagation fix
# from PR #2 review (murubhas, 2026-10-22).
#
# Context: install-r615.sh installs whatever point release the CUDA repo
# currently serves on the 615-open branch, which can be LATER than the
# configured NVIDIA_DRIVER_VERSION branch selector. The fix makes the
# version actually installed on the image the single source of truth for
# all downstream metadata:
#   - 02-build-ami.sh reads the version Packer downloaded from the built
#     image, overwrites the AMI's nvidia-driver-version tag with it, and
#     records it to .state keyed by AMI id.
#   - 03-add-gpu-node.sh refuses to create a node group unless that recorded
#     version exists for the exact AMI id being used (no silent fallback to
#     the branch-selector env var), and renders the node group's
#     nvidia-driver tag from it.
#   - common.sh's render_gpu_nodegroup_config now requires the discovered
#     version as an explicit argument.
#
# No real AWS/Packer/eksctl/kubectl calls are made:
# tests/mocks-build-ami/{aws,packer,eksctl,kubectl} are prepended to PATH and
# driven by MOCK_* environment variables. Each test asserts the script's exit
# code AND, where it matters, which calls were (or were not) issued -- recorded
# in MOCK_CALL_LOG -- plus the rendered node-group tag content.
#
# Usage: tests/run-build-ami-tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
MOCKS_DIR="${TESTS_DIR}/mocks-build-ami"
BUILD_AMI_SCRIPT="${ROOT_DIR}/scripts/02-build-ami.sh"
ADD_GPU_NODE_SCRIPT="${ROOT_DIR}/scripts/03-add-gpu-node.sh"
COMMON_SCRIPT="${ROOT_DIR}/scripts/common.sh"
AMI_DIR="${ROOT_DIR}/ami"
VERSION_FILE="${AMI_DIR}/installed-driver-version.txt"
MANIFEST_FILE="${AMI_DIR}/manifest.json"

pass_count=0
fail_count=0

# 02-build-ami.sh and the packer mock both write into the real ami/ dir
# (installed-driver-version.txt, manifest.json -- both gitignored build
# artifacts). Preserve anything already there so running the suite never
# disturbs a developer's working tree, and restore it on exit.
BACKUP_DIR="$(mktemp -d)"
for f in "${VERSION_FILE}" "${MANIFEST_FILE}"; do
  [[ -e "${f}" ]] && cp -p "${f}" "${BACKUP_DIR}/$(basename "${f}").orig"
done
cleanup_ami_artifacts() {
  rm -f "${VERSION_FILE}" "${MANIFEST_FILE}"
  for f in "${VERSION_FILE}" "${MANIFEST_FILE}"; do
    local orig="${BACKUP_DIR}/$(basename "${f}").orig"
    [[ -e "${orig}" ]] && cp -p "${orig}" "${f}"
  done
  rm -rf "${BACKUP_DIR}"
}
trap cleanup_ami_artifacts EXIT

# --- Shared per-test scaffolding --------------------------------------------

# Prepares a clean per-test STATE_DIR and call log, runs the given script
# under the mocked tools with whatever MOCK_* env the caller exported, and
# captures exit code, combined output, and the call log. Also clears the
# gitignored ami/ build artifacts before each run so a previous test can't
# leak state into the next.
run_script() {
  local script="$1"
  WORK_DIR="$(mktemp -d)"
  export MOCK_CALL_LOG="${WORK_DIR}/calls.log"
  touch "${MOCK_CALL_LOG}"
  export STATE_DIR="${WORK_DIR}/.state"
  mkdir -p "${STATE_DIR}"
  export MOCK_AMI_DIR="${AMI_DIR}"
  export AWS_REGION="${AWS_REGION:-us-east-2}"
  export CLUSTER_NAME="${CLUSTER_NAME:-mock-cluster}"
  rm -f "${VERSION_FILE}" "${MANIFEST_FILE}"

  set +e
  LAST_OUTPUT="$(PATH="${MOCKS_DIR}:${PATH}" bash "${script}" 2>&1)"
  LAST_EXIT_CODE=$?
  set -e
  LAST_CALL_LOG="$(cat "${MOCK_CALL_LOG}")"
  LAST_STATE_DIR="${WORK_DIR}/.state"
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

assert_output_contains() {
  local needle="$1" label="$2"
  if printf '%s' "${LAST_OUTPUT}" | grep -qF -- "${needle}"; then
    return 0
  fi
  echo "    FAIL (${label}): expected output to contain '${needle}'" >&2
  echo "    --- output ---" >&2
  echo "${LAST_OUTPUT}" | sed 's/^/    /' >&2
  return 1
}

assert_file_contains() {
  local file="$1" expected="$2" label="$3"
  if [[ -f "${file}" ]] && [[ "$(<"${file}")" == "${expected}" ]]; then
    return 0
  fi
  echo "    FAIL (${label}): expected ${file} to contain '${expected}', got '$( [[ -f "${file}" ]] && cat "${file}" || echo "<missing>")'" >&2
  return 1
}

run_test() {
  local name="$1"
  shift
  echo "RUNNING: ${name}"
  unset MOCK_INSTALLED_DRIVER_VERSION MOCK_PACKER_SKIP_VERSION_FILE \
    MOCK_BUILT_AMI_ID MOCK_NODEGROUP_EXISTS NVIDIA_DRIVER_VERSION \
    AMI_ID AWS_REGION CLUSTER_NAME
  if "$@"; then
    echo "  PASS: ${name}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${name}"
    fail_count=$((fail_count + 1))
  fi
}

# ============================================================================
# 02-build-ami.sh: the AMI tag + recorded state must reflect the version
# actually installed, not the configured branch selector.
# ============================================================================

# The headline case: the CUDA repo advanced past the configured selector, so
# the installed point release differs from NVIDIA_DRIVER_VERSION. The AMI tag
# must be overwritten with the DISCOVERED version, and the recorded state
# files must carry it too.
test_build_ami_tags_discovered_version_when_repo_advanced() {
  export NVIDIA_DRIVER_VERSION=615.71.09   # what we asked for
  export MOCK_INSTALLED_DRIVER_VERSION=615.71.10   # what the repo served
  export MOCK_BUILT_AMI_ID=ami-0d15c0accede00001
  run_script "${BUILD_AMI_SCRIPT}"
  assert_exit_code 0 "build-ami with a valid discovered version should succeed" \
    && assert_call_made "ec2 create-tags .*nvidia-driver-version.*615.71.10" \
         "AMI tag must be overwritten with the DISCOVERED version 615.71.10" \
    && assert_call_not_made "ec2 create-tags .*615.71.09" \
         "AMI tag must NOT carry the configured branch selector 615.71.09" \
    && assert_file_contains "${LAST_STATE_DIR}/ami-id.${MOCK_BUILT_AMI_ID}.installed-driver-version" \
         "615.71.10" "AMI-id-keyed state file must record the discovered version" \
    && assert_file_contains "${LAST_STATE_DIR}/installed-driver-version" \
         "615.71.10" "generic installed-driver-version state file must record the discovered version"
}

# Muru's "further drift" case: the repo advances AGAIN (.10 selector ->
# .11 installed). Same mechanism, different numbers -- makes it explicit that
# the fix is not hard-coded to a single hop.
test_build_ami_tags_discovered_version_further_drift() {
  export NVIDIA_DRIVER_VERSION=615.71.10   # what we asked for this time
  export MOCK_INSTALLED_DRIVER_VERSION=615.71.11   # repo advanced again
  export MOCK_BUILT_AMI_ID=ami-0f00fee10000b0001
  run_script "${BUILD_AMI_SCRIPT}"
  assert_exit_code 0 "build-ami should succeed on a further point-release drift" \
    && assert_call_made "ec2 create-tags .*nvidia-driver-version.*615.71.11" \
         "AMI tag must carry the newly discovered version 615.71.11" \
    && assert_call_not_made "ec2 create-tags .*615.71.10" \
         "AMI tag must NOT carry the configured selector 615.71.10" \
    && assert_file_contains "${LAST_STATE_DIR}/ami-id.${MOCK_BUILT_AMI_ID}.installed-driver-version" \
         "615.71.11" "keyed state file must record the further-drifted version"
}

# When Packer does not produce the downloaded version file at all, the script
# must fail closed rather than fall back to the branch selector or leave the
# AMI mistagged.
test_build_ami_fails_when_version_file_missing() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_PACKER_SKIP_VERSION_FILE=true
  export MOCK_BUILT_AMI_ID=ami-00f11e000000f0001
  run_script "${BUILD_AMI_SCRIPT}"
  assert_exit_code 1 "missing downloaded version file must fail the build" \
    && assert_call_not_made "ec2 create-tags" \
         "no tag overwrite should happen when the version is unknown"
}

# A malformed version (not matching ^615\.N\.N$) must be rejected, not tagged.
test_build_ami_rejects_malformed_version() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_INSTALLED_DRIVER_VERSION=not-a-version
  export MOCK_BUILT_AMI_ID=ami-0a1f0e00000000001
  run_script "${BUILD_AMI_SCRIPT}"
  assert_exit_code 1 "a malformed installed version must fail the build" \
    && assert_call_not_made "ec2 create-tags" \
         "a malformed version must not be written to the AMI tag"
}

# A driver that resolved onto a DIFFERENT branch (e.g. 570.x) is off-branch
# and must be rejected by the same ^615\. guard.
test_build_ami_rejects_off_branch_version() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_INSTALLED_DRIVER_VERSION=570.86.15
  export MOCK_BUILT_AMI_ID=ami-00ffb12a0c0000001
  run_script "${BUILD_AMI_SCRIPT}"
  assert_exit_code 1 "an off-branch (non-615) installed version must fail the build" \
    && assert_call_not_made "ec2 create-tags" \
         "an off-branch version must not be written to the AMI tag"
}

# ============================================================================
# 03-add-gpu-node.sh: the node group must be labelled from the recorded
# discovered version, and must fail closed when it is unavailable for the
# exact AMI id in use -- never silently fall back to NVIDIA_DRIVER_VERSION.
# ============================================================================

# 03-add-gpu-node.sh needs a keyed version file seeded into the STATE_DIR
# before it runs, so this helper allocates the STATE_DIR, seeds the file (when
# a version is given), and runs the script in one shot. Leaving the version
# empty exercises the fail-closed path.
run_add_gpu_node_with_recorded_version() {
  local ami_id="$1" recorded_version="$2"
  WORK_DIR="$(mktemp -d)"
  export MOCK_CALL_LOG="${WORK_DIR}/calls.log"
  touch "${MOCK_CALL_LOG}"
  export STATE_DIR="${WORK_DIR}/.state"
  mkdir -p "${STATE_DIR}"
  export MOCK_AMI_DIR="${AMI_DIR}"
  export AWS_REGION="${AWS_REGION:-us-east-2}"
  export CLUSTER_NAME="${CLUSTER_NAME:-mock-cluster}"
  export AMI_ID="${ami_id}"
  if [[ -n "${recorded_version}" ]]; then
    printf '%s\n' "${recorded_version}" \
      >"${STATE_DIR}/ami-id.${ami_id}.installed-driver-version"
  fi
  rm -f "${VERSION_FILE}" "${MANIFEST_FILE}"
  set +e
  LAST_OUTPUT="$(PATH="${MOCKS_DIR}:${PATH}" bash "${ADD_GPU_NODE_SCRIPT}" 2>&1)"
  LAST_EXIT_CODE=$?
  set -e
  LAST_CALL_LOG="$(cat "${MOCK_CALL_LOG}")"
  LAST_RENDERED_NODEGROUP="${STATE_DIR}/eksctl-gpu-nodegroup.yaml"
}

test_add_gpu_node_happy_path_uses_discovered_version() {
  export NVIDIA_DRIVER_VERSION=615.71.09   # branch selector; must NOT win
  export MOCK_NODEGROUP_EXISTS=false
  run_add_gpu_node_with_recorded_version ami-0deadbeef00000001 615.71.10
  assert_exit_code 0 "add-gpu-node should succeed when the version is recorded" \
    && assert_call_made "eksctl create nodegroup" \
         "node group should be created on the happy path" \
    && { grep -q 'nvidia-driver: "615.71.10"' "${LAST_RENDERED_NODEGROUP}" \
         || { echo "    FAIL: rendered node group did not carry nvidia-driver 615.71.10" >&2; \
              sed 's/^/    /' "${LAST_RENDERED_NODEGROUP}" >&2; false; }; } \
    && { ! grep -q 'nvidia-driver: "615.71.09"' "${LAST_RENDERED_NODEGROUP}" \
         || { echo "    FAIL: rendered node group leaked the branch selector 615.71.09" >&2; false; }; }
}

# Fail-closed: no recorded version for this AMI id (e.g. AMI_ID points at a
# preserved/old AMI this workflow did not just build) -> refuse, do NOT create
# a node group, and do NOT fall back to NVIDIA_DRIVER_VERSION.
test_add_gpu_node_fails_closed_without_recorded_version() {
  export NVIDIA_DRIVER_VERSION=615.71.10   # present, but must not be used
  export MOCK_NODEGROUP_EXISTS=false
  run_add_gpu_node_with_recorded_version ami-0cafef00d00000001 ""
  assert_exit_code 1 "missing recorded version for this AMI must fail closed" \
    && assert_call_not_made "eksctl create nodegroup" \
         "no node group must be created without a recorded driver version"
}

# A corrupt recorded version must also be refused, not rendered into the tag.
test_add_gpu_node_rejects_malformed_recorded_version() {
  export MOCK_NODEGROUP_EXISTS=false
  run_add_gpu_node_with_recorded_version ami-0badbad0000000001 "garbage"
  assert_exit_code 1 "a malformed recorded version must fail closed" \
    && assert_call_not_made "eksctl create nodegroup" \
         "no node group must be created from a malformed recorded version"
}

# ============================================================================
# End-to-end cross-component agreement (Muru's explicit ask): run 02-build-ami
# then 03-add-gpu-node against the SAME STATE_DIR, and confirm the single
# discovered version agrees across every metadata surface it touches -- the
# AMI tag (ec2 create-tags), the recorded state files, and the node group's
# rendered nvidia-driver tag -- while the configured branch selector appears
# on NONE of them.
# ============================================================================
test_end_to_end_version_agreement_across_components() {
  local selector=615.71.09 discovered=615.71.10 ami_id=ami-0e2ee2e000000001
  WORK_DIR="$(mktemp -d)"
  export MOCK_CALL_LOG="${WORK_DIR}/calls.log"
  touch "${MOCK_CALL_LOG}"
  export STATE_DIR="${WORK_DIR}/.state"
  mkdir -p "${STATE_DIR}"
  export MOCK_AMI_DIR="${AMI_DIR}"
  export AWS_REGION=us-east-2
  export CLUSTER_NAME=mock-cluster
  export NVIDIA_DRIVER_VERSION="${selector}"
  export MOCK_INSTALLED_DRIVER_VERSION="${discovered}"
  export MOCK_BUILT_AMI_ID="${ami_id}"
  export MOCK_NODEGROUP_EXISTS=false
  rm -f "${VERSION_FILE}" "${MANIFEST_FILE}"

  local ok=1
  set +e
  local build_out add_out build_rc add_rc
  build_out="$(PATH="${MOCKS_DIR}:${PATH}" bash "${BUILD_AMI_SCRIPT}" 2>&1)"; build_rc=$?
  # 03 reads AMI_ID; point it at the just-built AMI so it uses the keyed file
  # 02 recorded, exactly as the real `run.sh build-ami && run.sh add-gpu-node`
  # sequence would.
  export AMI_ID="${ami_id}"
  add_out="$(PATH="${MOCKS_DIR}:${PATH}" bash "${ADD_GPU_NODE_SCRIPT}" 2>&1)"; add_rc=$?
  set -e
  local call_log; call_log="$(cat "${MOCK_CALL_LOG}")"
  local rendered="${STATE_DIR}/eksctl-gpu-nodegroup.yaml"

  if [[ "${build_rc}" -ne 0 ]]; then echo "    FAIL: build-ami exited ${build_rc}" >&2; echo "${build_out}" | sed 's/^/    /' >&2; ok=0; fi
  if [[ "${add_rc}" -ne 0 ]]; then echo "    FAIL: add-gpu-node exited ${add_rc}" >&2; echo "${add_out}" | sed 's/^/    /' >&2; ok=0; fi
  # AMI tag
  if ! printf '%s\n' "${call_log}" | grep -q "ec2 create-tags .*nvidia-driver-version.*${discovered}"; then
    echo "    FAIL: AMI tag did not carry discovered ${discovered}" >&2; ok=0; fi
  # Recorded state files
  if [[ "$(<"${STATE_DIR}/installed-driver-version")" != "${discovered}" ]]; then
    echo "    FAIL: generic state file != ${discovered}" >&2; ok=0; fi
  if [[ "$(<"${STATE_DIR}/ami-id.${ami_id}.installed-driver-version")" != "${discovered}" ]]; then
    echo "    FAIL: keyed state file != ${discovered}" >&2; ok=0; fi
  # Node-group rendered tag
  if ! grep -q "nvidia-driver: \"${discovered}\"" "${rendered}"; then
    echo "    FAIL: rendered node group did not carry discovered ${discovered}" >&2
    [[ -f "${rendered}" ]] && sed 's/^/    /' "${rendered}" >&2; ok=0; fi
  # The selector must appear on NONE of the metadata surfaces.
  if printf '%s\n' "${call_log}" | grep -q "ec2 create-tags .*${selector}"; then
    echo "    FAIL: selector ${selector} leaked into the AMI tag" >&2; ok=0; fi
  if grep -q "nvidia-driver: \"${selector}\"" "${rendered}" 2>/dev/null; then
    echo "    FAIL: selector ${selector} leaked into the node group tag" >&2; ok=0; fi

  rm -rf "${WORK_DIR}"
  [[ "${ok}" -eq 1 ]]
}

# ============================================================================
# common.sh render_gpu_nodegroup_config: now requires the discovered version
# as an explicit second argument.
# ============================================================================

# Calling the function with no version argument must error, not silently
# render an empty/stale tag.
test_render_requires_version_argument() {
  WORK_DIR="$(mktemp -d)"
  export STATE_DIR="${WORK_DIR}/.state"
  mkdir -p "${STATE_DIR}"
  set +e
  LAST_OUTPUT="$(
    source "${COMMON_SCRIPT}"
    render_gpu_nodegroup_config ami-0e57000000000001 2>&1
  )"
  LAST_EXIT_CODE=$?
  set -e
  rm -rf "${WORK_DIR}"
  assert_exit_code 1 "render_gpu_nodegroup_config must fail without a version argument" \
    && assert_output_contains "requires the actual installed driver version" \
         "error message should name the missing version argument"
}

# With an explicit version argument, the function must render that exact
# version into the node group's nvidia-driver tag.
test_render_uses_explicit_version_argument() {
  WORK_DIR="$(mktemp -d)"
  export STATE_DIR="${WORK_DIR}/.state"
  mkdir -p "${STATE_DIR}"
  set +e
  (
    source "${COMMON_SCRIPT}"
    render_gpu_nodegroup_config ami-0e57000000000001 615.71.42
  )
  LAST_EXIT_CODE=$?
  set -e
  local rendered="${STATE_DIR}/eksctl-gpu-nodegroup.yaml"
  local ok=0
  if [[ "${LAST_EXIT_CODE}" -eq 0 ]] && grep -q 'nvidia-driver: "615.71.42"' "${rendered}"; then
    ok=1
  else
    echo "    FAIL: expected nvidia-driver 615.71.42 in rendered config (exit ${LAST_EXIT_CODE})" >&2
    [[ -f "${rendered}" ]] && sed 's/^/    /' "${rendered}" >&2
  fi
  rm -rf "${WORK_DIR}"
  [[ "${ok}" -eq 1 ]]
}

# ============================================================================

run_test "build-ami tags the DISCOVERED version when repo advanced past selector" \
  test_build_ami_tags_discovered_version_when_repo_advanced
run_test "build-ami tags the DISCOVERED version on a further drift (.10 -> .11)" \
  test_build_ami_tags_discovered_version_further_drift
run_test "build-ami fails closed when Packer produced no version file" \
  test_build_ami_fails_when_version_file_missing
run_test "build-ami rejects a malformed installed version" \
  test_build_ami_rejects_malformed_version
run_test "build-ami rejects an off-branch (non-615) installed version" \
  test_build_ami_rejects_off_branch_version
run_test "add-gpu-node renders the recorded DISCOVERED version into the node tag" \
  test_add_gpu_node_happy_path_uses_discovered_version
run_test "add-gpu-node fails closed when no version is recorded for the AMI" \
  test_add_gpu_node_fails_closed_without_recorded_version
run_test "add-gpu-node rejects a malformed recorded version" \
  test_add_gpu_node_rejects_malformed_recorded_version
run_test "end-to-end version agreement across AMI tag, state, and node group" \
  test_end_to_end_version_agreement_across_components
run_test "render_gpu_nodegroup_config requires the version argument" \
  test_render_requires_version_argument
run_test "render_gpu_nodegroup_config uses the explicit version argument" \
  test_render_uses_explicit_version_argument

echo
echo "=== ${pass_count} passed, ${fail_count} failed ==="
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
