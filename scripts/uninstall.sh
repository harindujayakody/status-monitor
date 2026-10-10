#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Safe Two-Mode Uninstaller
# ==============================================================================
# Supports:
#   - Mode 1 (Preserve Data): Removes project containers & network while
#     preserving monitoring history, TLS certificates, .env, and backups.
#   - Mode 2 (Full Removal): Removes project containers, network, and
#     application data after preview, optional backup, and explicit confirmation.
#   - Dry-Run (--dry-run): Previews all actions without modifying the system.
# Never modifies Docker Engine, unrelated containers, SSH keys, or iptables.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/backup.sh
source "${SCRIPT_DIR}/backup.sh"

verify_safe_removal_scope() {
    local target="$1"
    if [[ -z "${target}" || "${target}" == "/" || "${target}" == "/opt" || "${target}" == "/usr" || "${target}" == "/var" || "${target}" == "/home" || "${target}" == "/root" || "${target}" == "${HOME:-/root}" ]]; then
        msg_error "Safety check blocked unsafe removal path: '${target}'"
        return 1
    fi
    return 0
}

show_uninstall_preview() {
    local mode="$1"
    local rdir="$2"

    print_section "UNINSTALL DELETION PREVIEW (MODE: ${mode})"
    printf '  %sResources Scoped for Removal:%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    • Containers : infiax-caddy, infiax-uptime-kuma, infiax-beszel-hub, infiax-beszel-agent\n'
    printf '    • Network    : infiax_monitor_net (Compose project: %s)\n' "${ISM_COMPOSE_PROJECT}"
    printf '    • CLI Link   : /usr/local/bin/infiax-monitor (if present)\n'

    if [[ "${mode}" == "full" ]]; then
        printf '    • App Data   : %s/data (Uptime Kuma DB, Beszel DB, TLS certs)\n' "${rdir}"
        printf '    • Config     : %s/.env, compose.yaml, Caddyfile\n' "${rdir}"
    else
        printf '\n  %sResources Explicitly Preserved (Mode 1 — Preserve Data):%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
        printf '    • Uptime Kuma history  : %s/data/uptime-kuma\n' "${rdir}"
        printf '    • Beszel Hub history   : %s/data/beszel\n' "${rdir}"
        printf '    • TLS Certificates     : %s/data/caddy\n' "${rdir}"
        printf '    • Environment & Keys   : %s/.env\n' "${rdir}"
        printf '    • Backup Archives      : %s/backups\n' "${rdir}"
    fi

    printf '\n  %sUntouched System Components:%s\n' "${C_DIM}" "${C_RESET}"
    printf '    • Docker Engine, unrelated containers/volumes, SSH keys, and Oracle iptables rules.\n'
}

run_uninstaller() {
    local mode=""
    local dry_run=0
    local delete_backups=0

    while (( $# > 0 )); do
        case "$1" in
            --dry-run|-n)
                dry_run=1
                ;;
            --preserve-data|--mode=preserve)
                mode="preserve"
                ;;
            --full|--mode=full)
                mode="full"
                ;;
            --delete-backups)
                delete_backups=1
                ;;
            --yes|-y)
                export ISM_ASSUME_YES=1
                ;;
            *)
                msg_error "Unknown uninstall option: $1"
                return 1
                ;;
        esac
        shift
    done

    local rdir
    rdir="$(get_runtime_dir)"
    if ! verify_safe_removal_scope "${rdir}"; then
        return 1
    fi

    if (( dry_run == 0 )); then
        require_root
    fi

    # Interactive mode selection if not specified via CLI flags
    if [[ -z "${mode}" ]]; then
        if (( dry_run == 1 )); then
            mode="preserve"
        else
            print_section "UNINSTALL INFIAX STATUS MONITOR"
            printf '  Select Uninstall Mode:\n'
            printf '    %s1) Mode 1 — Preserve Data (Recommended)%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}"
            printf '       Removes project containers and Docker network only.\n'
            printf '       Preserves monitoring history, TLS certificates, .env secrets, and backups.\n\n'
            printf '    %s2) Mode 2 — Full Removal%s\n' "${C_RED}${C_BOLD}" "${C_RESET}"
            printf '       Removes project containers, network, monitoring databases, and configuration.\n\n'
            printf '    0) Cancel\n\n'
            local mchoice
            mchoice="$(prompt_input "Choose option (1, 2, or 0)" "1")"
            case "${mchoice}" in
                1) mode="preserve" ;;
                2) mode="full" ;;
                *)
                    msg_info "Uninstall cancelled."
                    return 0
                    ;;
            esac
        fi
    fi

    show_uninstall_preview "${mode}" "${rdir}"

    if (( dry_run == 1 )); then
        printf '\n'
        msg_ok "[DRY-RUN] Preview completed. No containers, networks, or files were modified."
        return 0
    fi

    printf '\n'
    if ! confirm_action "Are you sure you want to proceed with '${mode}' uninstallation?" "n"; then
        msg_info "Uninstall cancelled."
        return 0
    fi

    if [[ "${mode}" == "full" ]]; then
        if [[ -d "${rdir}/data" ]]; then
            if confirm_action "Would you like to create a final backup archive before deleting data?" "y"; then
                create_backup || msg_warn "Backup could not be completed; proceeding to confirmation."
            fi
        fi

        if [[ "${ISM_ASSUME_YES:-0}" != "1" ]] && [[ -t 0 ]]; then
            local confirm_word
            confirm_word="$(prompt_input "Type DELETE in uppercase to confirm permanent removal of monitoring data" "")"
            if [[ "${confirm_word}" != "DELETE" ]]; then
                msg_info "Confirmation word did not match 'DELETE'. Uninstall aborted safely."
                return 0
            fi
        fi
    fi

    # 1. Remove project containers and network (never volumes outside project)
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if [[ -f "${rdir}/compose.yaml" ]]; then
            msg_info "Stopping and removing Infiax Status Monitor containers and network..."
            run_compose down --remove-orphans || true
        else
            local c
            for c in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
                if docker inspect "${c}" >/dev/null 2>&1; then
                    docker rm -f "${c}" >/dev/null 2>&1 || true
                fi
            done
            docker network rm infiax_monitor_net >/dev/null 2>&1 || true
        fi
        msg_ok "Removed project containers and private Docker network."
    else
        msg_info "Docker daemon not active; skipped container teardown."
    fi

    # 2. Remove CLI symlink if present
    if [[ -L /usr/local/bin/infiax-monitor ]]; then
        rm -f /usr/local/bin/infiax-monitor
        msg_ok "Removed /usr/local/bin/infiax-monitor CLI symlink."
    fi

    # 3. Handle Mode 1 vs Mode 2 filesystem cleanup
    if [[ "${mode}" == "preserve" ]]; then
        rm -f "${rdir}/data/beszel-socket/beszel.sock" 2>/dev/null || true
        msg_ok "Uninstall (Mode 1 — Preserve Data) complete."
        msg_info "Preserved data, TLS certificates, .env, and backups in: ${rdir}"
    else
        rm -rf "${rdir}/data"
        rm -f "${rdir}/.env"
        msg_ok "Removed application data (${rdir}/data) and .env configuration."

        if [[ -d "${rdir}/backups" ]]; then
            if (( delete_backups == 1 )) || confirm_action "Also delete backup archives in ${rdir}/backups?" "n"; then
                rm -rf "${rdir}/backups"
                msg_ok "Removed backup archives (${rdir}/backups)."
            else
                msg_info "Preserved backup archives at ${rdir}/backups."
            fi
        fi

        # If running against installed runtime directory (not git development checkout), clean runtime files
        if [[ ! -d "${rdir}/.git" && "${rdir}" == "${INSTALL_DIR}" ]]; then
            rm -rf "${rdir}/scripts" "${rdir}/docs" "${rdir}/logs" \
                   "${rdir}/compose.yaml" "${rdir}/Caddyfile" "${rdir}/.env.example" \
                   "${rdir}/install.sh" "${rdir}/monitor.sh" "${rdir}/uninstall.sh" 2>/dev/null || true
            rmdir "${rdir}" 2>/dev/null || true
        fi
        msg_ok "Uninstall (Mode 2 — Full Removal) complete."
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    run_uninstaller "$@"
fi
