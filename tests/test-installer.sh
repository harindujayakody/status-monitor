#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Installer & Configuration Test Suite
# ==============================================================================

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${TEST_DIR}/.." && pwd)"

# shellcheck source=scripts/common.sh
source "${REPO_ROOT}/scripts/common.sh"
# shellcheck source=scripts/configure.sh
source "${REPO_ROOT}/scripts/configure.sh"
# shellcheck source=scripts/beszel-agent.sh
source "${REPO_ROOT}/scripts/beszel-agent.sh"

TMP_INSTALL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ism-test-installer-XXXXXX")"
trap 'rm -rf "${TMP_INSTALL_DIR}"' EXIT

export INSTALL_DIR="${TMP_INSTALL_DIR}"
export ISM_ALLOW_NON_ROOT=1
export ISM_ALLOW_UNSUPPORTED_OS=1
export ISM_ASSUME_YES=1

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
        printf '[FAIL] %s (expected failure but succeeded)\n' "${desc}" >&2
        fail_cnt=$(( fail_cnt + 1 ))
    else
        printf '[PASS] %s\n' "${desc}"
        pass_cnt=$(( pass_cnt + 1 ))
    fi
}

printf '=== Running Installer & Configuration Tests ===\n'

# 1. Syntax check across all shell scripts
for s in "${REPO_ROOT}/install.sh" "${REPO_ROOT}/monitor.sh" "${REPO_ROOT}/uninstall.sh" "${REPO_ROOT}/scripts/"*.sh "${REPO_ROOT}/tests/"*.sh; do
    assert_ok "bash -n syntax check: $(basename "${s}")" bash -n "${s}"
done

# 2. CLI help and version flags
assert_ok "install.sh --help" bash "${REPO_ROOT}/install.sh" --help
assert_ok "install.sh --version" bash "${REPO_ROOT}/install.sh" --version

# 3. Domain validation (including underscore rejection rule)
assert_ok "validate_domain accepts status.example.com" validate_domain "status.example.com"
assert_ok "validate_domain accepts dev-monitor.example.com" validate_domain "dev-monitor.example.com"
assert_fail "validate_domain rejects underscore dev_monitor.example.com" validate_domain "dev_monitor.example.com"
assert_fail "validate_domain rejects URL scheme https://status.example.com" validate_domain "https://status.example.com"
assert_fail "validate_domain rejects empty string" validate_domain ""

# 4. IPv4 & Email validation
assert_ok "validate_ipv4 accepts 203.0.113.10" validate_ipv4 "203.0.113.10"
assert_fail "validate_ipv4 rejects 999.213.54.54" validate_ipv4 "999.213.54.54"
assert_ok "validate_email accepts admin@example.com" validate_email "admin@example.com"

# 5. Runtime directory preparation & idempotency
assert_ok "prepare_runtime_directories initial run" prepare_runtime_directories "${TMP_INSTALL_DIR}"
assert_ok ".env file created" test -f "${TMP_INSTALL_DIR}/.env"

# Verify idempotency: customize .env, re-run prepare_runtime_directories, verify custom value preserved
set_env_val "STATUS_DOMAIN" "custom-status.example.com" "${TMP_INSTALL_DIR}/.env"
prepare_runtime_directories "${TMP_INSTALL_DIR}" >/dev/null
val="$(get_env_val "STATUS_DOMAIN" "" "${TMP_INSTALL_DIR}/.env")"
if [[ "${val}" == "custom-status.example.com" ]]; then
    printf '[PASS] Installer idempotency: existing .env values preserved on re-run\n'
    pass_cnt=$(( pass_cnt + 1 ))
else
    printf '[FAIL] Installer idempotency: expected custom-status.example.com, got %s\n' "${val}" >&2
    fail_cnt=$(( fail_cnt + 1 ))
fi

# 6. Auto-sync Beszel Hub ED25519 public key
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestBeszelHubPublicKeyMaterialHere beszel\n' > "${TMP_INSTALL_DIR}/data/beszel/id_ed25519.pub"
assert_ok "auto_sync_beszel_key populates BESZEL_AGENT_KEY from Hub key" auto_sync_beszel_key
synced_key="$(get_env_val "BESZEL_AGENT_KEY" "" "${TMP_INSTALL_DIR}/.env")"
assert_ok "validate_beszel_ssh_key accepts synced key" validate_beszel_ssh_key "${synced_key}"

# 7. Stack config validation (Caddyfile & compose.yaml)
assert_ok "validate_stack_configs passes" validate_stack_configs

# 8. Dry-run installer execution
assert_ok "install.sh --dry-run --allow-unsupported-os" bash "${REPO_ROOT}/install.sh" --dry-run --allow-unsupported-os

printf '=== Installer Tests Complete: %d passed, %d failed ===\n' "${pass_cnt}" "${fail_cnt}"
(( fail_cnt == 0 ))
