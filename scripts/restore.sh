#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Verified Backup Restore System
# ==============================================================================
# Validates backup integrity (SHA-256, tar structure, SQLite PRAGMA check),
# creates a pre-restore safety backup, and restores configuration and data.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/backup.sh
source "${SCRIPT_DIR}/backup.sh"

restore_backup() {
    require_root
    local target_archive="${1:-}"
    local skip_pre_backup="${2:-0}"
    local rdir
    rdir="$(get_runtime_dir)"
    local backup_dir="${rdir}/backups"

    print_section "RESTORE MONITORING DATA FROM BACKUP"

    if [[ -z "${target_archive}" ]]; then
        list_backups
        local backups=()
        while IFS= read -r f; do
            [[ -n "${f}" ]] && backups+=("${f}")
        done < <(find "${backup_dir}" -maxdepth 1 -type f -name 'infiax-backup-*.tar.gz' 2>/dev/null | sort -r)

        if (( ${#backups[@]} == 0 )); then
            msg_error "No backup archives available to restore."
            return 1
        fi

        if [[ ! -t 0 ]] || [[ "${ISM_NONINTERACTIVE:-0}" == "1" ]]; then
            target_archive="${backups[0]}"
            msg_info "Non-interactive restore selected latest backup: $(basename "${target_archive}")"
        else
            printf '\n'
            local sel
            sel="$(prompt_input "Enter backup number (1-${#backups[@]}) or full path" "1")"
            if [[ "${sel}" =~ ^[0-9]+$ ]] && (( sel >= 1 && sel <= ${#backups[@]} )); then
                target_archive="${backups[$(( sel - 1 ))]}"
            else
                target_archive="${sel}"
            fi
        fi
    fi

    if [[ ! -f "${target_archive}" && -f "${backup_dir}/${target_archive}" ]]; then
        target_archive="${backup_dir}/${target_archive}"
    fi

    msg_info "Validating backup archive: ${target_archive}..."
    if ! verify_backup_archive "${target_archive}"; then
        msg_error "Restore aborted: backup archive failed integrity verification."
        return 1
    fi
    msg_ok "Archive SHA-256 and structure verified."

    local stage_dir
    stage_dir="$(mktemp -d "${backup_dir}/.restore-stage-XXXXXX")"
    chmod 700 "${stage_dir}"

    tar -C "${stage_dir}" -xzf "${target_archive}"

    # Verify any SQLite databases inside the extracted staging area before touching live data
    if command -v sqlite3 >/dev/null 2>&1 && [[ -d "${stage_dir}/data" ]]; then
        local staged_db
        while IFS= read -r staged_db; do
            [[ -z "${staged_db}" ]] && continue
            local check_res
            check_res="$(sqlite3 "${staged_db}" "PRAGMA integrity_check;" 2>/dev/null || printf 'failed')"
            if [[ "${check_res}" != "ok" ]]; then
                rm -rf "${stage_dir}"
                msg_error "Restore aborted: corrupted SQLite database in archive (${staged_db})."
                return 1
            fi
            msg_ok "Verified SQLite database integrity in backup: $(basename "${staged_db}")"
        done < <(find "${stage_dir}/data" -type f -name '*.db' 2>/dev/null)
    fi

    printf '\n'
    msg_warn "Restoring will replace current application data in ${rdir}/data and configuration in ${rdir}/.env."
    if ! confirm_action "Proceed with restoring $(basename "${target_archive}")?" "n"; then
        rm -rf "${stage_dir}"
        msg_info "Restore cancelled by user."
        return 0
    fi

    if [[ "${skip_pre_backup}" != "1" ]] && [[ -d "${rdir}/data" ]]; then
        msg_info "Creating pre-restore safety backup of current state..."
        create_backup >/dev/null
        msg_ok "Pre-restore safety snapshot saved."
    fi

    local docker_was_running=0
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^infiax-'; then
            docker_was_running=1
            msg_info "Stopping running containers before data replacement..."
            run_compose stop
        fi
    fi

    if [[ -d "${stage_dir}/data" ]]; then
        rm -rf "${rdir}/data"
        mkdir -p "${rdir}/data"
        cp -Rp "${stage_dir}/data/." "${rdir}/data/"
        mkdir -p "${rdir}/data/beszel-socket"
        chmod 750 "${rdir}/data" 2>/dev/null || true
    fi

    if [[ -f "${stage_dir}/config/.env" ]]; then
        cp -p "${stage_dir}/config/.env" "${rdir}/.env"
        chmod 600 "${rdir}/.env"
    fi
    if [[ -f "${stage_dir}/config/Caddyfile" ]]; then
        cp -p "${stage_dir}/config/Caddyfile" "${rdir}/Caddyfile"
    fi
    if [[ -f "${stage_dir}/config/compose.yaml" ]]; then
        cp -p "${stage_dir}/config/compose.yaml" "${rdir}/compose.yaml"
    fi

    rm -rf "${stage_dir}"
    msg_ok "Application data and configuration restored from $(basename "${target_archive}")."

    if (( docker_was_running == 1 )); then
        msg_info "Restarting monitoring stack..."
        run_compose up -d
        msg_ok "Monitoring services restarted."
    fi

    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    restore_backup "${1:-}" "${2:-0}"
fi
