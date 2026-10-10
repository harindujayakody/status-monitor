#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — One-Click Production Installer
# ==============================================================================
# Idempotent, low-memory-optimized installer for Ubuntu Server 22.04 LTS
# (AMD64 & ARM64). Preserves Oracle Cloud iptables rules and deploys the
# monitoring stack to /opt/infiax-status-monitor.
#
# Usage:
#   sudo bash install.sh
#   sudo bash install.sh --dry-run
#   sudo bash install.sh --yes
# ==============================================================================

set -euo pipefail

resolve_script_dir() {
    local src="${BASH_SOURCE[0]}"
    while [[ -L "${src}" ]]; do
        local dir
        dir="$(cd -P "$(dirname "${src}")" && pwd)"
        src="$(readlink "${src}")"
        [[ "${src}" != /* ]] && src="${dir}/${src}"
    done
    cd -P "$(dirname "${src}")" && pwd
}
ROOT_DIR="$(resolve_script_dir)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=scripts/preflight.sh
source "${ROOT_DIR}/scripts/preflight.sh"
# shellcheck source=scripts/docker-install.sh
source "${ROOT_DIR}/scripts/docker-install.sh"
# shellcheck source=scripts/configure.sh
source "${ROOT_DIR}/scripts/configure.sh"
# shellcheck source=scripts/beszel-agent.sh
source "${ROOT_DIR}/scripts/beszel-agent.sh"
# shellcheck source=scripts/services.sh
source "${ROOT_DIR}/scripts/services.sh"
# shellcheck source=scripts/health-check.sh
source "${ROOT_DIR}/scripts/health-check.sh"

show_install_help() {
    print_banner "Production Installer"
    cat <<'EOF'
Usage:
  sudo bash install.sh [OPTIONS]

Options:
  --dry-run, -n             Run all preflight checks and preview changes without installing
  --yes, -y                 Non-interactive mode (accept defaults and confirmations)
  --status-domain <domain>  Override Uptime Kuma domain (default: status.example.com)
  --beszel-domain <domain>  Override Beszel Hub domain (default: monitor.example.com)
  --acme-email <email>      Override Let's Encrypt email (default: admin@example.com)
  --allow-unsupported-os    Allow running on non-Ubuntu systems for testing
  --help, -h                Show this help message
  --version, -v             Show version information
EOF
}

wait_for_stack_initialization() {
    local max_wait="${1:-45}"
    local elapsed=0
    msg_info "Waiting for containers to initialize (up to ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local all_ready=1
        local cname
        for cname in infiax-uptime-kuma infiax-beszel-hub infiax-caddy; do
            local st hlth
            st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'missing')"
            hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cname}" 2>/dev/null || printf 'none')"
            if [[ "${st}" != "running" ]] || [[ "${hlth}" == "starting" ]]; then
                all_ready=0
                break
            fi
        done

        if (( all_ready == 1 )); then
            msg_ok "Core monitoring containers are running and initialized."
            return 0
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
    done

    msg_warn "Containers are still completing initial startup checks; proceeding to verification."
    return 0
}

run_installer() {
    local dry_run=0
    local override_status_domain=""
    local override_beszel_domain=""
    local override_email=""

    while (( $# > 0 )); do
        case "$1" in
            --dry-run|-n)
                dry_run=1
                ;;
            --yes|-y)
                export ISM_ASSUME_YES=1
                ;;
            --status-domain)
                shift
                override_status_domain="${1:-}"
                ;;
            --beszel-domain)
                shift
                override_beszel_domain="${1:-}"
                ;;
            --acme-email)
                shift
                override_email="${1:-}"
                ;;
            --allow-unsupported-os)
                export ISM_ALLOW_UNSUPPORTED_OS=1
                ;;
            --help|-h)
                show_install_help
                exit 0
                ;;
            --version|-v)
                printf 'Infiax Status Monitor Installer v%s\n' "${ISM_VERSION}"
                exit 0
                ;;
            *)
                msg_error "Unknown installer option: $1 (use --help for usage)"
                exit 1
                ;;
        esac
        shift
    done

    print_banner "One-Click Production Installer"

    # Steps 1-11: Root check & comprehensive preflight checks
    if (( dry_run == 0 )); then
        require_root
    fi

    msg_step "1/6" "Running system, resource, DNS, port, and firewall preflight checks..."
    if ! run_preflight_checks "$(( 1 - dry_run ))"; then
        msg_error "Preflight checks reported critical errors. Resolve the issues above before installing."
        return 1
    fi

    # Steps 12-13: Explain intended changes & request confirmation
    print_section "INSTALLATION PLAN & INTENDED CHANGES"
    printf '  • %sTarget Runtime Path%s : %s\n' "${C_BOLD}" "${C_RESET}" "${INSTALL_DIR}"
    printf '  • %sHost Packages%s       : ca-certificates, curl, gnupg, lsb-release, dnsutils, jq, sqlite3, tar\n' "${C_BOLD}" "${C_RESET}"
    printf '  • %sContainer Runtime%s   : Docker Engine + Docker Compose v2 (official APT repository)\n' "${C_BOLD}" "${C_RESET}"
    printf '  • %sStack Containers%s    :\n' "${C_BOLD}" "${C_RESET}"
    printf '      1. infiax-caddy       (Public TCP 80, TCP/UDP 443 -> automatic HTTPS)\n'
    printf '      2. infiax-uptime-kuma (Private bridge :3001 -> Uptime Kuma v2)\n'
    printf '      3. infiax-beszel-hub  (Private bridge :8090 -> Beszel Hub)\n'
    printf '      4. infiax-beszel-agent(Unix socket /beszel_socket/beszel.sock -> VPS Metrics)\n'
    printf '  • %sFirewall Policy%s     : Read-only preservation of existing Oracle Cloud iptables & InstanceServices\n' "${C_BOLD}" "${C_RESET}"

    if (( dry_run == 1 )); then
        printf '\n'
        msg_ok "[DRY-RUN] Preflight and installation plan verified. No system changes were made."
        return 0
    fi

    printf '\n'
    if ! confirm_action "Proceed with installing Infiax Status Monitor to ${INSTALL_DIR}?" "y"; then
        msg_info "Installation cancelled by user."
        return 0
    fi

    # Steps 14-15: Install host dependencies & Docker Engine
    msg_step "2/6" "Installing host dependencies and Docker Engine..."
    install_docker_engine

    # Steps 16-17: Prepare runtime directories & generate .env configuration
    msg_step "3/6" "Preparing runtime directories and environment configuration..."
    prepare_runtime_directories "${INSTALL_DIR}"

    local env_file="${INSTALL_DIR}/.env"
    if [[ -n "${override_status_domain}" ]]; then
        validate_domain "${override_status_domain}"
        set_env_val "STATUS_DOMAIN" "${override_status_domain}" "${env_file}"
    fi
    if [[ -n "${override_beszel_domain}" ]]; then
        validate_domain "${override_beszel_domain}"
        set_env_val "BESZEL_DOMAIN" "${override_beszel_domain}" "${env_file}"
        set_env_val "BESZEL_APP_URL" "https://${override_beszel_domain}" "${env_file}"
        set_env_val "BESZEL_HUB_URL" "https://${override_beszel_domain}" "${env_file}"
    fi
    if [[ -n "${override_email}" ]]; then
        set_env_val "ACME_EMAIL" "${override_email}" "${env_file}"
    fi

    # Prompt to customize domains if interactive and not --yes
    if [[ "${ISM_ASSUME_YES:-0}" != "1" ]] && [[ -t 0 ]] && [[ -z "${override_status_domain}" ]]; then
        local cur_st cur_bz
        cur_st="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
        cur_bz="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
        printf '\n  Current Domains: Uptime Kuma = %s%s%s | Beszel Hub = %s%s%s\n' \
            "${C_CYAN}" "${cur_st}" "${C_RESET}" "${C_CYAN}" "${cur_bz}" "${C_RESET}"
        if confirm_action "Would you like to customize the domain names before starting?" "n"; then
            configure_domains_interactive
        fi
    fi

    # Create convenience CLI symlink /usr/local/bin/infiax-monitor
    if [[ -d /usr/local/bin ]]; then
        ln -sf "${INSTALL_DIR}/monitor.sh" /usr/local/bin/infiax-monitor
        msg_ok "Installed CLI shortcut: /usr/local/bin/infiax-monitor"
    fi

    # Steps 18-19: Validate Docker Compose & Caddy configuration
    msg_step "4/6" "Validating Docker Compose and Caddyfile configurations..."
    validate_stack_configs

    # Steps 20-21: Start containers & wait for initialization
    msg_step "5/6" "Starting monitoring containers and syncing Beszel Agent key..."
    start_services
    wait_for_stack_initialization 45
    if auto_sync_beszel_key 2>/dev/null; then
        run_compose up -d beszel-agent >/dev/null 2>&1 || true
    fi

    # Steps 22-23: Perform health checks & verify HTTPS
    msg_step "6/6" "Running post-install health and HTTPS verification..."
    run_health_checks || true

    # Steps 24-25: Final URLs & Next-Step Guidance
    local final_status final_beszel
    final_status="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    final_beszel="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    print_section "INSTALLATION COMPLETE — NEXT STEPS"
    print_kv "Uptime Kuma Dashboard" "https://${final_status}"
    print_kv "Beszel Hub Dashboard" "https://${final_beszel}"
    print_kv "Runtime Location" "${INSTALL_DIR}"
    print_kv "Management Interface" "sudo ${INSTALL_DIR}/monitor.sh  (or: sudo infiax-monitor)"
    printf '\n'
    printf '  %s1. Create Administrator Accounts Immediately:%s\n' "${C_BOLD}" "${C_RESET}"
    printf '     Visit both URLs above to create your admin credentials on first login.\n\n'
    printf '  %s2. Pair Beszel Agent (Local VPS Metrics):%s\n' "${C_BOLD}" "${C_RESET}"
    printf '     • In Beszel Hub (https://%s), click "+ Add System".\n' "${final_beszel}"
    printf '     • Set Name = %s and Host/IP = %s/beszel_socket/beszel.sock%s\n' \
        "$(hostname 2>/dev/null || printf 'infiax-vps')" "${C_GREEN}" "${C_RESET}"
    printf '     • Or run %ssudo ./monitor.sh%s -> Option 05 (Configure Beszel Agent).\n\n' "${C_CYAN}" "${C_RESET}"
    printf '  %s3. Configure Telegram Notifications:%s\n' "${C_BOLD}" "${C_RESET}"
    printf '     • Run %ssudo ./monitor.sh%s -> Option 12 (Telegram Setup Guide) & Option 13 (Test).\n\n' "${C_CYAN}" "${C_RESET}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    run_installer "$@"
fi
