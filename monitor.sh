#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Interactive Terminal Management Interface & CLI
# ==============================================================================
# Brand: Infiax (#0a66c2)
# Interactive TUI (18 operations) + Non-interactive CLI for automation.
#
# Examples:
#   sudo ./monitor.sh
#   sudo ./monitor.sh status
#   sudo ./monitor.sh logs
#   sudo ./monitor.sh backup
#   sudo ./monitor.sh health
#   sudo ./monitor.sh uninstall --dry-run
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# shellcheck source=scripts/telegram.sh
source "${ROOT_DIR}/scripts/telegram.sh"
# shellcheck source=scripts/backup.sh
source "${ROOT_DIR}/scripts/backup.sh"
# shellcheck source=scripts/restore.sh
source "${ROOT_DIR}/scripts/restore.sh"
# shellcheck source=scripts/update.sh
source "${ROOT_DIR}/scripts/update.sh"
# shellcheck source=scripts/health-check.sh
source "${ROOT_DIR}/scripts/health-check.sh"
# shellcheck source=scripts/uninstall.sh
source "${ROOT_DIR}/scripts/uninstall.sh"

show_cli_help() {
    print_banner "Terminal Management Interface & CLI"
    cat <<'EOF'
Usage:
  sudo ./monitor.sh [COMMAND] [OPTIONS]

Interactive Mode:
  sudo ./monitor.sh                 Launch the interactive Infiax terminal menu

Non-Interactive Commands:
  info                              01. Display system and environment information
  preflight                         02. Run system, DNS, port, and firewall checks
  install [options]                 03. Install or repair the monitoring stack
  domains                           04. Configure Uptime Kuma and Beszel domains
  beszel-agent                      05. Configure and pair the Beszel Agent
  start                             06. Start monitoring stack containers
  stop                              07. Stop monitoring stack containers
  restart                           08. Restart monitoring stack containers
  update                            09. Backup, pull, and update stack containers
  status                            10. Show container status and resource usage
  logs [service] [lines]            11. View container or installer logs
  telegram                          12. Launch guided Telegram notification setup
  test-telegram                     13. Send a live test alert to Telegram
  backup [--list]                   14. Create or list verified data backups
  restore [archive]                 15. Restore monitoring data from a backup
  health                            16. Run comprehensive stack health checks
  troubleshoot                      17. Run automated troubleshooting diagnostics
  uninstall [--dry-run|--full]      18. Safely uninstall stack (or preview with --dry-run)

Global Flags:
  --help, -h                        Show this help screen
  --version, -v                     Display version information
EOF
}

render_main_menu() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local status_domain beszel_domain ram_used ram_total
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    ram_used="$(get_used_ram_mib)"
    ram_total="$(get_total_ram_mib)"

    if [[ -t 1 ]] && [[ "${ISM_NO_CLEAR:-0}" != "1" ]]; then
        clear 2>/dev/null || true
    fi

    printf '\n'
    printf '%s%s  I N F I A X%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '%s%s  STATUS MONITOR%s %s(v%s)%s\n' "${C_BOLD}" "${C_WHITE}" "${C_RESET}" "${C_GRAY}" "${ISM_VERSION}" "${C_RESET}"
    printf '%s  ────────────────────────────────────%s\n' "${C_BRAND}" "${C_RESET}"
    printf '  %sStatus:%s https://%s   %sBeszel:%s https://%s\n' \
        "${C_DIM}" "${C_RESET}" "${status_domain}" "${C_DIM}" "${C_RESET}" "${beszel_domain}"
    printf '  %sHost:%s   %s (%s)   %sRAM:%s %s/%s MiB\n' \
        "${C_DIM}" "${C_RESET}" "$(hostname 2>/dev/null || printf 'vps')" "$(detect_arch)" \
        "${C_DIM}" "${C_RESET}" "${ram_used}" "${ram_total}"
    printf '%s  ────────────────────────────────────%s\n\n' "${C_BRAND}" "${C_RESET}"

    printf '  %s%sSERVER%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s01.%s System Information\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s02.%s Preflight Checks\n\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"

    printf '  %s%sINSTALLATION%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s03.%s Install Monitoring Stack\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s04.%s Configure Domains\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s05.%s Configure Beszel Agent\n\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"

    printf '  %s%sSERVICES%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s06.%s Start Services\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s07.%s Stop Services\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s08.%s Restart Services\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s09.%s Update Services\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s10.%s Service Status\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s11.%s View Logs\n\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"

    printf '  %s%sNOTIFICATIONS%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s12.%s Telegram Setup Guide\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s13.%s Test Notifications\n\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"

    printf '  %s%sMAINTENANCE%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s14.%s Backup Data\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s15.%s Restore Backup\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s16.%s Health Checks\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"
    printf '    %s17.%s Troubleshooting\n\n' "${C_CYAN}${C_BOLD}" "${C_RESET}"

    printf '  %s%sREMOVAL%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '    %s18.%s Uninstall Monitoring Stack\n\n' "${C_RED}${C_BOLD}" "${C_RESET}"

    printf '    %s00.%s Exit\n' "${C_GRAY}${C_BOLD}" "${C_RESET}"
    printf '%s  ────────────────────────────────────%s\n' "${C_BRAND}" "${C_RESET}"
}

dispatch_menu_option() {
    local opt="$1"
    case "${opt}" in
        1|01)
            show_system_info
            ;;
        2|02)
            run_preflight_checks 0 || true
            ;;
        3|03)
            bash "${ROOT_DIR}/install.sh" || true
            ;;
        4|04)
            configure_domains_interactive || true
            ;;
        5|05)
            configure_beszel_agent_interactive || true
            ;;
        6|06)
            start_services || true
            ;;
        7|07)
            stop_services || true
            ;;
        8|08)
            restart_services || true
            ;;
        9|09)
            update_services || true
            ;;
        10)
            show_service_status || true
            ;;
        11)
            view_service_logs || true
            ;;
        12)
            telegram_setup_guide || true
            ;;
        13)
            send_telegram_test_notification || true
            ;;
        14)
            create_backup || true
            ;;
        15)
            restore_backup || true
            ;;
        16)
            run_health_checks || true
            ;;
        17)
            run_troubleshooting_diagnostics || true
            ;;
        18)
            run_uninstaller || true
            ;;
        0|00|q|Q|exit|quit)
            msg_info "Exiting Infiax Status Monitor. Goodbye!"
            exit 0
            ;;
        *)
            msg_error "Invalid option '${opt}'. Please enter a number between 00 and 18."
            return 1
            ;;
    esac
    return 0
}

run_interactive_loop() {
    while true; do
        render_main_menu
        local choice=""
        printf '  %s%sSelect option [00-18]:%s ' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
        if ! read -r choice; then
            printf '\n'
            exit 0
        fi
        choice="$(printf '%s' "${choice}" | tr -d '[:space:]')"
        if [[ -z "${choice}" ]]; then
            continue
        fi
        if dispatch_menu_option "${choice}"; then
            pause_prompt
        else
            sleep 1
        fi
    done
}

main() {
    setup_traps

    if (( $# == 0 )); then
        run_interactive_loop
        exit 0
    fi

    local cmd="$1"
    shift

    export ISM_NONINTERACTIVE=1

    case "${cmd}" in
        --help|-h|help)
            show_cli_help
            exit 0
            ;;
        --version|-v|version)
            printf 'Infiax Status Monitor v%s\n' "${ISM_VERSION}"
            exit 0
            ;;
        info|system-info)
            show_system_info
            ;;
        preflight|check)
            run_preflight_checks 0
            ;;
        install)
            unset ISM_NONINTERACTIVE
            bash "${ROOT_DIR}/install.sh" "$@"
            ;;
        domains|configure-domains)
            unset ISM_NONINTERACTIVE
            configure_domains_interactive
            ;;
        beszel-agent|pair)
            unset ISM_NONINTERACTIVE
            configure_beszel_agent_interactive
            ;;
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            ;;
        update)
            update_services
            ;;
        status)
            show_service_status
            ;;
        logs)
            view_service_logs "${1:-}" "${2:-80}"
            ;;
        telegram)
            unset ISM_NONINTERACTIVE
            telegram_setup_guide
            ;;
        test-telegram)
            send_telegram_test_notification
            ;;
        backup)
            if [[ "${1:-}" == "--list" || "${1:-}" == "list" ]]; then
                list_backups
            else
                create_backup
            fi
            ;;
        restore)
            restore_backup "${1:-}" "${2:-0}"
            ;;
        health|health-check)
            run_health_checks
            ;;
        troubleshoot|diag)
            run_troubleshooting_diagnostics
            ;;
        uninstall)
            unset ISM_NONINTERACTIVE
            run_uninstaller "$@"
            ;;
        menu)
            unset ISM_NONINTERACTIVE
            run_interactive_loop
            ;;
        *)
            msg_error "Unknown command: '${cmd}'. Run './monitor.sh --help' for usage."
            exit 1
            ;;
    esac
}

main "$@"
