#!/usr/bin/env bash
# Regression tests for ami/install-r615.sh's driver-version discovery and
# post-install verification logic, covering the cases PR #2 review
# (murubhas, 2026-10-22) asked be tested with clean-failure assertions:
# normal/further drift, cross-component agreement at the install layer
# (the DISCOVERED version is what gets versionlocked, DKMS-checked, grepped
# in the rpm -qa list, and written to /etc/eks-runai-nvidia-driver-version),
# rejection of a non-R615 major, and clean failure (NOT silent success) on
# missing RPM discovery, DNF failure, versionlock failure, and DKMS error.
#
# No real packages are installed and nothing is written under /etc:
# tests/mocks-install-r615/{sudo,dnf,rpm,dkms,nvidia-ctk,systemctl,uname,tee}
# are prepended to PATH and driven by MOCK_* environment variables. `sudo`
# strips itself and re-dispatches to the mocked tool; `tee` redirects the
# /etc version-file write to a test-controlled path so the test can assert
# exactly what install-r615.sh recorded.
#
# Usage: tests/run-install-r615-tests.sh
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${TESTS_DIR}/.." && pwd)"
MOCKS_DIR="${TESTS_DIR}/mocks-install-r615"
INSTALL_SCRIPT="${ROOT_DIR}/ami/install-r615.sh"

pass_count=0
fail_count=0

# Runs install-r615.sh under the mocked tools with whatever MOCK_* / input
# env the caller exported. Captures exit code, combined output, the call log,
# and the version string the script wrote to its /etc target (via the tee
# mock). Each call gets a fresh work dir.
run_install() {
  WORK_DIR="$(mktemp -d)"
  export MOCK_CALL_LOG="${WORK_DIR}/calls.log"
  touch "${MOCK_CALL_LOG}"
  export MOCK_ETC_VERSION_FILE="${WORK_DIR}/eks-runai-nvidia-driver-version"
  export MOCK_ETC_DIR="${WORK_DIR}"
  : >"${MOCK_ETC_VERSION_FILE}"

  set +e
  LAST_OUTPUT="$(PATH="${MOCKS_DIR}:${PATH}" bash "${INSTALL_SCRIPT}" 2>&1)"
  LAST_EXIT_CODE=$?
  set -e
  LAST_CALL_LOG="$(cat "${MOCK_CALL_LOG}")"
  LAST_RECORDED_VERSION="$(cat "${MOCK_ETC_VERSION_FILE}" 2>/dev/null || true)"
  rm -rf "${WORK_DIR}"
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

assert_exit_nonzero() {
  local label="$1"
  if [[ "${LAST_EXIT_CODE}" -ne 0 ]]; then
    return 0
  fi
  echo "    FAIL (${label}): expected a nonzero exit (clean failure), got 0 (silent success)" >&2
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
  echo "    FAIL (${label}): expected NO call matching '${pattern}', but found one" >&2
  echo "    --- call log ---" >&2
  echo "${LAST_CALL_LOG}" | sed 's/^/    /' >&2
  return 1
}

assert_recorded_version() {
  local expected="$1" label="$2"
  if [[ "${LAST_RECORDED_VERSION}" == "${expected}" ]]; then
    return 0
  fi
  echo "    FAIL (${label}): expected /etc version file to contain '${expected}', got '${LAST_RECORDED_VERSION}'" >&2
  return 1
}

run_test() {
  local name="$1"
  shift
  echo "RUNNING: ${name}"
  unset NVIDIA_DRIVER_VERSION MOCK_RPM_INSTALLED_VERSION MOCK_RPM_DISCOVERY_FAILS \
    MOCK_RPM_QA_OMITS_VERSION MOCK_DNF_MODULE_INSTALL_FAILS MOCK_DNF_VERSIONLOCK_FAILS \
    MOCK_DKMS_ERROR MOCK_UNAME_R
  if "$@"; then
    echo "  PASS: ${name}"
    pass_count=$((pass_count + 1))
  else
    echo "  FAIL: ${name}"
    fail_count=$((fail_count + 1))
  fi
}

# --- Cross-component agreement at the install layer: when the repo serves a
# LATER point release than the configured selector, the DISCOVERED version --
# not the selector -- is what gets versionlocked, DKMS-checked, grepped in the
# installed-package list, and written to /etc. (Muru's "normal drift .09->.10"
# plus the versionlock/DKMS/recorded-version half of cross-component
# agreement.) ---
test_discovery_drift_09_to_10() {
  export NVIDIA_DRIVER_VERSION=615.71.09   # selector
  export MOCK_RPM_INSTALLED_VERSION=615.71.10   # what the repo installed
  run_install
  assert_exit_code 0 "a valid discovered R615 version should succeed" \
    && assert_recorded_version "615.71.10" "the DISCOVERED version is written to /etc" \
    && assert_call_made "dnf versionlock add .*615.71.10" \
         "versionlock must pin the DISCOVERED version" \
    && assert_call_not_made "dnf versionlock add .*615.71.09" \
         "versionlock must NOT pin the configured selector" \
    && assert_call_made "dkms .*-v 615.71.10" \
         "dkms status must be checked for the DISCOVERED version"
}

# --- Muru's "further drift .10 -> .11": same mechanism, next hop. ---
test_discovery_drift_10_to_11() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_RPM_INSTALLED_VERSION=615.71.11
  run_install
  assert_exit_code 0 "a further-drifted discovered version should succeed" \
    && assert_recorded_version "615.71.11" "the further-drifted version is written to /etc" \
    && assert_call_made "dnf versionlock add .*615.71.11" \
         "versionlock must pin the further-drifted version"
}

# --- Rejection of a non-R615 major: if dnf somehow resolved the stream onto a
# different branch, the installed-version re-check must refuse. ---
test_rejects_non_r615_installed_version() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_RPM_INSTALLED_VERSION=570.86.15
  run_install
  assert_exit_nonzero "a non-R615 installed version must be refused" \
    && assert_recorded_version "" "nothing should be written to /etc on refusal" \
    && assert_call_not_made "dnf versionlock add" \
         "no versionlock should happen for an off-branch install"
}

# --- Rejection of a non-R615 SELECTOR up front (the script's first guard). ---
test_rejects_non_r615_selector() {
  export NVIDIA_DRIVER_VERSION=570.86.15
  run_install
  assert_exit_nonzero "a non-R615 selector must be refused before install" \
    && assert_call_not_made "dnf module install" \
         "no module install should run for an off-branch selector"
}

# --- Clean failure on missing RPM discovery (driver package not actually
# installed / rpm -q fails): must NOT silently succeed. ---
test_fails_on_missing_rpm_discovery() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_RPM_DISCOVERY_FAILS=true
  run_install
  assert_exit_nonzero "failed rpm discovery must fail closed" \
    && assert_recorded_version "" "nothing should be written to /etc when discovery failed" \
    && assert_call_not_made "dnf versionlock add" \
         "no versionlock should happen when the version is unknown"
}

# --- Clean failure on DNF module-install error. ---
test_fails_on_dnf_install_error() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_DNF_MODULE_INSTALL_FAILS=true
  run_install
  assert_exit_nonzero "a dnf module install failure must fail closed" \
    && assert_recorded_version "" "nothing should be written to /etc on a dnf failure"
}

# --- Clean failure on versionlock error. ---
test_fails_on_versionlock_error() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_DNF_VERSIONLOCK_FAILS=true
  run_install
  assert_exit_nonzero "a versionlock failure must fail closed" \
    && assert_recorded_version "" "nothing should be written to /etc when versionlock failed"
}

# --- Clean failure on DKMS error: module reported not-installed. The grep for
# "<version>.*installed" must fail the script, not pass silently. ---
test_fails_on_dkms_notbuilt() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_DKMS_ERROR=notbuilt
  run_install
  assert_exit_nonzero "a DKMS module not reporting 'installed' must fail closed" \
    && assert_recorded_version "" "nothing should be written to /etc on a DKMS error"
}

# --- Clean failure on DKMS producing no status at all. ---
test_fails_on_dkms_empty() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_DKMS_ERROR=empty
  run_install
  assert_exit_nonzero "an empty DKMS status must fail closed"
}

# --- Clean failure when the installed-package list (rpm -qa) does not contain
# the discovered version -- the verification grep must fail the build. ---
test_fails_when_rpm_qa_omits_version() {
  export NVIDIA_DRIVER_VERSION=615.71.10
  export MOCK_RPM_INSTALLED_VERSION=615.71.10
  export MOCK_RPM_QA_OMITS_VERSION=true
  run_install
  assert_exit_nonzero "a package list missing the discovered version must fail closed"
}

run_test "discovery drift .09 -> .10 uses the discovered version throughout" \
  test_discovery_drift_09_to_10
run_test "discovery further drift .10 -> .11 uses the discovered version" \
  test_discovery_drift_10_to_11
run_test "non-R615 installed version is refused" \
  test_rejects_non_r615_installed_version
run_test "non-R615 selector is refused before install" \
  test_rejects_non_r615_selector
run_test "missing RPM discovery fails closed" \
  test_fails_on_missing_rpm_discovery
run_test "DNF module-install error fails closed" \
  test_fails_on_dnf_install_error
run_test "versionlock error fails closed" \
  test_fails_on_versionlock_error
run_test "DKMS module-not-built fails closed" \
  test_fails_on_dkms_notbuilt
run_test "empty DKMS status fails closed" \
  test_fails_on_dkms_empty
run_test "rpm -qa missing the discovered version fails closed" \
  test_fails_when_rpm_qa_omits_version

echo
echo "=== ${pass_count} passed, ${fail_count} failed ==="
if [[ "${fail_count}" -gt 0 ]]; then
  exit 1
fi
