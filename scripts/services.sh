#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Container Lifecycle & Log Management
# ==============================================================================
# Implements Start (06), Stop (07), Restart (08), Status (10), and Logs (11).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/beszel-agent.sh
source "${SCRIPT_DIR}/beszel-agent.sh"

ensure_docker_available() {
    if ! command -v docker >/dev/null 2>&1; then
        msg_error "Docker CLI is not installed. Run './install.sh' or Menu Option 03 first."
        return 1
    fi
    if ! docker info >/dev/null 2>&1; then
        msg_error "Docker daemon is not running or current user lacks permissions (try running with sudo)."
        return 1
    fi
    return 0
}

start_services() {
    require_root
    ensure_docker_available
    local rdir
    rdir="$(get_runtime_dir)"
    ensure_env_file "${rdir}/.env"

    print_section "STARTING MONITORING SERVICES"
    msg_info "Starting core services (Uptime Kuma, Beszel Hub, Caddy)..."
    run_compose up -d uptime-kuma beszel caddy

    # Wait briefly for Beszel Hub to generate its ED25519 key on first run
    local tries=0
    while (( tries < 10 )); do
        if auto_sync_beszel_key 2>/dev/null; then
            break
        fi
        sleep 1
        tries=$(( tries + 1 ))
    done

    local agent_key
    agent_key="$(get_env_val "BESZEL_AGENT_KEY" "" "${rdir}/.env")"
    if [[ -n "${agent_key}" ]]; then
        msg_info "Starting Beszel Agent..."
        run_compose up -d beszel-agent
    else
        msg_warn "BESZEL_AGENT_KEY is not set yet. Run Menu Option 05 (Configure Beszel Agent) after creating your Beszel Hub admin account."
        run_compose up -d beszel-agent
    fi

    msg_ok "Monitoring stack start sequence completed."
    show_service_status
}

stop_services() {
    require_root
    ensure_docker_available
    print_section "STOPPING MONITORING SERVICES"
    run_compose stop
    msg_ok "All Infiax Status Monitor containers have been stopped."
}

restart_services() {
    require_root
    ensure_docker_available
    print_section "RESTARTING MONITORING SERVICES"
    auto_sync_beszel_key 2>/dev/null || true
    run_compose up -d --force-recreate
    msg_ok "All Infiax Status Monitor containers have been restarted."
    show_service_status
}

show_service_status() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    print_section "SERVICE STATUS & RESOURCE USAGE"

    local status_domain beszel_domain
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    print_kv "Uptime Kuma Endpoint" "https://${status_domain}"
    print_kv "Beszel Hub Endpoint" "https://${beszel_domain}"
    print_kv "Runtime Path" "${rdir}"
    printf '\n'

    if ! command -v docker >/dev/null 2>&1; then
        msg_warn "Docker CLI is not installed on this system."
        return 0
    fi
    if ! docker info >/dev/null 2>&1; then
        msg_warn "Cannot connect to Docker daemon (is Docker running, and did you use sudo?)."
        return 0
    fi

    printf '  %s%-22s %-14s %-14s %-24s%s\n' "${C_BOLD}" "CONTAINER" "STATE" "HEALTH" "IMAGE" "${C_RESET}"
    draw_line 74 "─"

    local cname
    for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
        if docker inspect "${cname}" >/dev/null 2>&1; then
            local state health image state_color
            state="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'unknown')"
            health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${cname}" 2>/dev/null || printf 'n/a')"
            image="$(docker inspect -f '{{.Config.Image}}' "${cname}" 2>/dev/null || printf 'unknown')"

            state_color="${C_YELLOW}"
            [[ "${state}" == "running" ]] && state_color="${C_GREEN}"
            [[ "${state}" == "exited" || "${state}" == "dead" ]] && state_color="${C_RED}"

            printf '  %-22s %s%-14s%s %-14s %s\n' "${cname}" "${state_color}" "${state}" "${C_RESET}" "${health}" "${image}"
        else
            printf '  %-22s %s%-14s%s %-14s %s\n' "${cname}" "${C_GRAY}" "not created" "${C_RESET}" "-" "-"
        fi
    done

    printf '\n  %sContainer Memory & CPU Snapshot:%s\n' "${C_BOLD}" "${C_RESET}"
    docker stats --no-stream --format "  {{.Name}}\tCPU: {{.CPUPerc}}\tMEM: {{.MemUsage}} ({{.MemPerc}})" \
        infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent 2>/dev/null || \
        printf '  %s(No running containers to query stats)%s\n' "${C_DIM}" "${C_RESET}"
}

view_service_logs() {
    local target_svc="${1:-}"
    local tail_lines="${2:-80}"

    print_section "VIEW SERVICE LOGS"

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        local logfile
        logfile="$(get_log_file)"
        msg_warn "Docker daemon unavailable; showing local installer/monitor log (${logfile}):"
        if [[ -f "${logfile}" ]]; then
            tail -n "${tail_lines}" "${logfile}"
        else
            msg_info "No log entries recorded yet."
        fi
        return 0
    fi

    if [[ -z "${target_svc}" ]] && [[ -t 0 ]] && [[ "${ISM_NONINTERACTIVE:-0}" != "1" ]]; then
        printf '  Select service logs to inspect:\n'
        printf '    1) All Services\n'
        printf '    2) Caddy Reverse Proxy (caddy)\n'
        printf '    3) Uptime Kuma (uptime-kuma)\n'
        printf '    4) Beszel Hub (beszel)\n'
        printf '    5) Beszel Agent (beszel-agent)\n'
        printf '    6) Installer & Management Log File\n\n'
        local choice
        choice="$(prompt_input "Select option (1-6)" "1")"
        case "${choice}" in
            2) target_svc="caddy" ;;
            3) target_svc="uptime-kuma" ;;
            4) target_svc="beszel" ;;
            5) target_svc="beszel-agent" ;;
            6)
                local logfile
                logfile="$(get_log_file)"
                msg_info "Showing last ${tail_lines} lines of ${logfile}:"
                [[ -f "${logfile}" ]] && tail -n "${tail_lines}" "${logfile}" || msg_info "Log file is empty."
                return 0
                ;;
            *) target_svc="" ;;
        esac
    fi

    if [[ -n "${target_svc}" ]]; then
        msg_info "Showing last ${tail_lines} lines for service '${target_svc}':"
        run_compose logs --no-color --tail="${tail_lines}" "${target_svc}"
    else
        msg_info "Showing last ${tail_lines} lines across all stack services:"
        run_compose logs --no-color --tail="${tail_lines}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-status}" in
        start) start_services ;;
        stop) stop_services ;;
        restart) restart_services ;;
        status) show_service_status ;;
        logs) view_service_logs "${2:-}" "${3:-80}" ;;
        *)
            msg_error "Unknown action: $1 (expected start|stop|restart|status|logs)"
            exit 1
            ;;
    esac
fi
