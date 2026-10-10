#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Safe Uninstaller Test Suite
# ==============================================================================

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

TMP_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ism-test-uninstall-XXXXXX")"
trap 'rm -rf "${TMP_INSTALL_DIR}"' EXIT

export INSTALL_DIR="${TMP_INSTALL_DIR}"
export ISM_ALLOW_NON_ROOT=1
export ISM_ASSUME_YES=1

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
# shellcheck source=scripts/configure.sh
source "${REPO_ROOT}/scripts/configure.sh"
# shellcheck source=scripts/uninstall.sh
source "${REPO_ROOT}/scripts/uninstall.sh"

pass_cnt=0
fail_cnt=0

assert_ok() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[PASS] %s\n' "${desc}"
        pass_cnt=$(( pass_cnt + 1 ))
    else
        printf '[FAIL] %s\n' "${desc}" >&2
        fail_cnt=$(( fail_cnt + 1 ))
    fi
}

assert_fail() {
    local desc="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        printf '[FAIL] %s (expected failure)\n' "${desc}" >&2
        fail_cnt=$(( fail_cnt + 1 ))
    else
        printf '[PASS] %s\n' "${desc}"
        pass_cnt=$(( pass_cnt + 1 ))
    fi
}

printf '=== Running Uninstaller Safety Tests ===\n'

prepare_runtime_directories "${TMP_INSTALL_DIR}" >/dev/null
printf 'keep-this-data\n' > "${TMP_INSTALL_DIR}/data/uptime-kuma/marker.txt"
printf 'keep-this-backup\n' > "${TMP_INSTALL_DIR}/backups/sample.tar.gz"

# 1. Verify scope guard blocks dangerous paths
assert_fail "verify_safe_removal_scope blocks /" verify_safe_removal_scope "/"
assert_fail "verify_safe_removal_scope blocks /opt" verify_safe_removal_scope "/opt"
assert_fail "verify_safe_removal_scope blocks HOME" verify_safe_removal_scope "${HOME:-/root}"
assert_ok "verify_safe_removal_scope allows ${TMP_INSTALL_DIR}" verify_safe_removal_scope "${TMP_INSTALL_DIR}"

# 2. Test --dry-run (nothing deleted)
assert_ok "uninstall.sh --dry-run" bash "${REPO_ROOT}/uninstall.sh" --dry-run
assert_ok "Dry-run preserved marker.txt" test -f "${TMP_INSTALL_DIR}/data/uptime-kuma/marker.txt"
assert_ok "Dry-run preserved .env" test -f "${TMP_INSTALL_DIR}/.env"

# 3. Test Mode 1: --preserve-data (data, .env, and backups preserved)
assert_ok "uninstall.sh --preserve-data --yes" bash "${REPO_ROOT}/uninstall.sh" --preserve-data --yes
assert_ok "Mode 1 preserved data/uptime-kuma/marker.txt" test -f "${TMP_INSTALL_DIR}/data/uptime-kuma/marker.txt"
assert_ok "Mode 1 preserved .env" test -f "${TMP_INSTALL_DIR}/.env"
assert_ok "Mode 1 preserved backups" test -f "${TMP_INSTALL_DIR}/backups/sample.tar.gz"

# 4. Test Mode 2: --full --yes (data and .env removed, backups preserved unless --delete-backups)
# Create a dummy .git directory so TMP_INSTALL_DIR only deletes data/.env first
mkdir -p "${TMP_INSTALL_DIR}/.git"
assert_ok "uninstall.sh --full --yes" bash "${REPO_ROOT}/uninstall.sh" --full --yes
assert_fail "Mode 2 removed data/uptime-kuma/marker.txt" test -f "${TMP_INSTALL_DIR}/data/uptime-kuma/marker.txt"
assert_fail "Mode 2 removed .env" test -f "${TMP_INSTALL_DIR}/.env"

printf '=== Uninstaller Tests Complete: %d passed, %d failed ===\n' "${pass_cnt}" "${fail_cnt}"
(( fail_cnt == 0 ))
