#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Terminal Menu, Backup & Restore Test Suite
# ==============================================================================

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

TMP_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ism-test-menu-XXXXXX")"
trap 'rm -rf "${TMP_INSTALL_DIR}"' EXIT

export INSTALL_DIR="${TMP_INSTALL_DIR}"
export ISM_ALLOW_NON_ROOT=1
export ISM_ALLOW_UNSUPPORTED_OS=1
export ISM_ASSUME_YES=1
export ISM_NO_CLEAR=1

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
# shellcheck source=scripts/configure.sh
source "${REPO_ROOT}/scripts/configure.sh"

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

printf '=== Running Terminal Menu, Backup & Restore Tests ===\n'

prepare_runtime_directories "${TMP_INSTALL_DIR}" >/dev/null

# 1. Test CLI flags & non-interactive subcommands
assert_ok "monitor.sh --help" bash "${REPO_ROOT}/monitor.sh" --help
assert_ok "monitor.sh --version" bash "${REPO_ROOT}/monitor.sh" --version
assert_ok "monitor.sh info" bash "${REPO_ROOT}/monitor.sh" info
assert_ok "monitor.sh preflight" bash "${REPO_ROOT}/monitor.sh" preflight
assert_ok "monitor.sh status" bash "${REPO_ROOT}/monitor.sh" status
assert_ok "monitor.sh health" bash "${REPO_ROOT}/monitor.sh" health
assert_ok "monitor.sh troubleshoot" bash "${REPO_ROOT}/monitor.sh" troubleshoot

# 2. Verify redirected output contains zero ANSI escape sequences
redirected_out="$(bash "${REPO_ROOT}/monitor.sh" info)"
if printf '%s' "${redirected_out}" | grep -q $'\033'; then
    printf '[FAIL] Redirected output contains ANSI escape sequences\n' >&2
    fail_cnt=$(( fail_cnt + 1 ))
else
    printf '[PASS] Redirected output is clean of ANSI escape codes\n'
    pass_cnt=$(( pass_cnt + 1 ))
fi

# 3. Test interactive menu navigation (Option 01 -> Option 00 Exit)
menu_out="$(printf '01\n00\n' | bash "${REPO_ROOT}/monitor.sh" 2>&1)"
if [[ "${menu_out}" == *"STATUS MONITOR"* && "${menu_out}" == *"System Uptime"* ]]; then
    printf '[PASS] Interactive TUI menu renders and executes Option 01 -> 00\n'
    pass_cnt=$(( pass_cnt + 1 ))
else
    printf '[FAIL] Interactive TUI menu failed to render expected output\n' >&2
    fail_cnt=$(( fail_cnt + 1 ))
fi

# 4. Test real SQLite backup creation, verification, and restoration
if command -v sqlite3 >/dev/null 2>&1; then
    db_path="${TMP_INSTALL_DIR}/data/uptime-kuma/kuma.db"
    sqlite3 "${db_path}" "CREATE TABLE monitor (id INTEGER PRIMARY KEY, url TEXT); INSERT INTO monitor VALUES (1, 'https://status.infiax.com');"
    set_env_val "BESZEL_DOMAIN" "dev-monitor.infiax.com" "${TMP_INSTALL_DIR}/.env"

    assert_ok "monitor.sh backup creates verified archive" bash "${REPO_ROOT}/monitor.sh" backup
    assert_ok "monitor.sh backup --list" bash "${REPO_ROOT}/monitor.sh" backup --list

    latest_archive="$(cat "${TMP_INSTALL_DIR}/backups/.latest_backup")"
    assert_ok "Backup archive file exists" test -f "${latest_archive}"
    assert_ok "Backup SHA-256 file exists" test -f "${latest_archive}.sha256"

    # Simulate accidental data deletion and config modification
    rm -f "${db_path}"
    set_env_val "BESZEL_DOMAIN" "broken.example.com" "${TMP_INSTALL_DIR}/.env"

    assert_ok "monitor.sh restore restores archive" bash "${REPO_ROOT}/monitor.sh" restore "${latest_archive}"

    restored_url="$(sqlite3 "${db_path}" "SELECT url FROM monitor WHERE id=1;")"
    restored_domain="$(get_env_val "BESZEL_DOMAIN" "" "${TMP_INSTALL_DIR}/.env")"
    if [[ "${restored_url}" == "https://status.infiax.com" && "${restored_domain}" == "dev-monitor.infiax.com" ]]; then
        printf '[PASS] SQLite database and .env restored and verified accurately\n'
        pass_cnt=$(( pass_cnt + 1 ))
    else
        printf '[FAIL] Restored data mismatch: url=%s domain=%s\n' "${restored_url}" "${restored_domain}" >&2
        fail_cnt=$(( fail_cnt + 1 ))
    fi
fi

printf '=== Menu & Backup Tests Complete: %d passed, %d failed ===\n' "${pass_cnt}" "${fail_cnt}"
(( fail_cnt == 0 ))
