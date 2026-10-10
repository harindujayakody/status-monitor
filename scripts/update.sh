#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Safe Stack Update Manager
# ==============================================================================
# Creates a verified pre-update backup, pulls pinned container updates,
# recreates services without losing persistent data, and verifies health.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/backup.sh
source "${SCRIPT_DIR}/backup.sh"
# shellcheck source=scripts/health-check.sh
source "${SCRIPT_DIR}/health-check.sh"

update_services() {
    require_root
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    ensure_env_file "${env_file}"

    print_section "UPDATE MONITORING SERVICES"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        msg_error "Docker daemon is not available. Cannot update containers."
        return 1
    fi

    print_kv "Caddy Image" "$(get_env_val "CADDY_IMAGE" "caddy:2.11.7-alpine" "${env_file}")"
    print_kv "Uptime Kuma Image" "$(get_env_val "UPTIME_KUMA_IMAGE" "louislam/uptime-kuma:2.5.6-slim" "${env_file}")"
    print_kv "Beszel Hub Image" "$(get_env_val "BESZEL_HUB_IMAGE" "henrygd/beszel:0.21.0" "${env_file}")"
    print_kv "Beszel Agent Image" "$(get_env_val "BESZEL_AGENT_IMAGE" "henrygd/beszel-agent:0.21.0" "${env_file}")"
    printf '\n'

    if ! confirm_action "Create a pre-update backup and pull/recreate stack containers?" "y"; then
        msg_info "Update cancelled."
        return 0
    fi

    msg_step "1/4" "Creating pre-update safety backup..."
    create_backup

    msg_step "2/4" "Pulling container images..."
    run_compose pull

    msg_step "3/4" "Recreating updated containers..."
    run_compose up -d --remove-orphans

    msg_step "4/4" "Pruning dangling container images..."
    docker image prune -f >/dev/null 2>&1 || true

    msg_ok "Service update completed. Running post-update health checks..."
    run_health_checks || true
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    update_services "$@"
fi
