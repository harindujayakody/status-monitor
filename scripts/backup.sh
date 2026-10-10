#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Verified Backup System (SQLite-Consistent)
# ==============================================================================
# Creates timestamped, permission-protected (0600) backup archives of all
# monitoring data, configuration, and TLS state. Uses 'sqlite3 .backup' for
# online SQLite consistency and verifies SHA-256 + tar integrity before success.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

compute_sha256() {
    local file="$1"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "${file}" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${file}" | awk '{print $1}'
    else
        openssl dgst -sha256 "${file}" | awk '{print $NF}'
    fi
}

list_backups() {
    local rdir
    rdir="$(get_runtime_dir)"
    local backup_dir="${rdir}/backups"

    print_section "AVAILABLE BACKUP ARCHIVES"
    if [[ ! -d "${backup_dir}" ]]; then
        msg_info "Backup directory (${backup_dir}) does not exist yet."
        return 0
    fi

    local backups=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] && backups+=("${f}")
    done < <(find "${backup_dir}" -maxdepth 1 -type f -name 'infiax-backup-*.tar.gz' 2>/dev/null | sort -r)

    if (( ${#backups[@]} == 0 )); then
        msg_info "No backups found in ${backup_dir}."
        return 0
    fi

    printf '  %s%-4s %-38s %-12s %-12s%s\n' "${C_BOLD}" "NO." "ARCHIVE FILENAME" "SIZE" "CHECKSUM" "${C_RESET}"
    draw_line 70 "─"
    local idx=1
    local bfile
    for bfile in "${backups[@]}"; do
        local bname size_str csum_status
        bname="$(basename "${bfile}")"
        size_str="$(du -h "${bfile}" 2>/dev/null | awk '{print $1}')"
        if [[ -f "${bfile}.sha256" ]]; then
            csum_status="${C_GREEN}Present${C_RESET}"
        else
            csum_status="${C_YELLOW}Missing${C_RESET}"
        fi
        printf '  [%02d] %-38s %-12s %s\n' "${idx}" "${bname}" "${size_str}" "${csum_status}"
        idx=$(( idx + 1 ))
    done
}

verify_backup_archive() {
    local archive_path="$1"
    if [[ ! -f "${archive_path}" ]]; then
        msg_error "Backup archive not found: ${archive_path}"
        return 1
    fi

    # 1. Verify SHA-256 checksum if .sha256 file exists
    if [[ -f "${archive_path}.sha256" ]]; then
        local expected_hash actual_hash
        expected_hash="$(awk '{print $1}' "${archive_path}.sha256")"
        actual_hash="$(compute_sha256 "${archive_path}")"
        if [[ -z "${expected_hash}" || "${expected_hash}" != "${actual_hash}" ]]; then
            msg_error "SHA-256 checksum mismatch for ${archive_path}!"
            return 1
        fi
    fi

    # 2. Verify tar.gz readability and manifest presence
    local contents
    if ! contents="$(tar -tzf "${archive_path}" 2>/dev/null)"; then
        msg_error "Archive ${archive_path} is corrupted or not a valid tar.gz archive."
        return 1
    fi

    if ! printf '%s\n' "${contents}" | grep -q "backup-manifest.json"; then
        msg_error "Archive ${archive_path} is missing backup-manifest.json."
        return 1
    fi

    return 0
}

prune_old_backups() {
    local backup_dir="$1"
    local keep_count="${2:-7}"
    if [[ ! "${keep_count}" =~ ^[0-9]+$ ]] || (( keep_count < 1 )); then
        keep_count=7
    fi

    local backups=()
    while IFS= read -r f; do
        [[ -n "${f}" ]] && backups+=("${f}")
    done < <(find "${backup_dir}" -maxdepth 1 -type f -name 'infiax-backup-*.tar.gz' 2>/dev/null | sort -r)

    local total="${#backups[@]}"
    if (( total <= keep_count )); then
        return 0
    fi

    local i="${keep_count}"
    while (( i < total )); do
        local old_file="${backups[$i]}"
        rm -f "${old_file}" "${old_file}.sha256"
        msg_info "Pruned old backup beyond retention limit (${keep_count}): $(basename "${old_file}")"
        i=$(( i + 1 ))
    done
}

create_backup() {
    require_root
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local backup_dir="${rdir}/backups"

    print_section "CREATING VERIFIED SYSTEM BACKUP"

    mkdir -p "${backup_dir}"
    chmod 700 "${backup_dir}"

    local ts
    ts="$(date -u '+%Y%m%d-%H%M%S')"
    local archive_name="infiax-backup-${ts}.tar.gz"
    local archive_path="${backup_dir}/${archive_name}"

    local stage_dir
    stage_dir="$(mktemp -d "${backup_dir}/.stage-${ts}-XXXXXX")"
    chmod 700 "${stage_dir}"

    msg_info "Staging configuration and persistent data from ${rdir}..."
    mkdir -p "${stage_dir}/config" "${stage_dir}/data"

    [[ -f "${rdir}/.env" ]] && cp -p "${rdir}/.env" "${stage_dir}/config/.env"
    [[ -f "${rdir}/compose.yaml" ]] && cp -p "${rdir}/compose.yaml" "${stage_dir}/config/compose.yaml"
    [[ -f "${rdir}/Caddyfile" ]] && cp -p "${rdir}/Caddyfile" "${stage_dir}/config/Caddyfile"

    if [[ -d "${rdir}/data" ]]; then
        # Copy directory tree excluding transient Unix socket files
        tar -C "${rdir}" --exclude="data/beszel-socket/*.sock" -cf - data 2>/dev/null | tar -C "${stage_dir}" -xf - 2>/dev/null || true
    fi

    # Perform consistent online SQLite backups for any .db files
    if command -v sqlite3 >/dev/null 2>&1 && [[ -d "${rdir}/data" ]]; then
        local db_file
        while IFS= read -r db_file; do
            [[ -z "${db_file}" ]] && continue
            local rel_path="${db_file#"${rdir}/"}"
            local staged_db="${stage_dir}/${rel_path}"
            mkdir -p "$(dirname "${staged_db}")"
            rm -f "${staged_db}" "${staged_db}-wal" "${staged_db}-shm"
            if sqlite3 "${db_file}" ".timeout 5000" ".backup '${staged_db}'" >/dev/null 2>&1; then
                local integrity
                integrity="$(sqlite3 "${staged_db}" "PRAGMA integrity_check;" 2>/dev/null || printf 'failed')"
                if [[ "${integrity}" == "ok" ]]; then
                    msg_ok "Consistent SQLite snapshot verified: ${rel_path}"
                else
                    rm -rf "${stage_dir}"
                    msg_error "SQLite integrity check failed for staged database: ${rel_path}"
                    return 1
                fi
            else
                cp -p "${db_file}" "${staged_db}"
                msg_warn "Used file copy fallback for SQLite database: ${rel_path}"
            fi
        done < <(find "${rdir}/data" -type f -name '*.db' 2>/dev/null)
    fi

    # Write backup manifest
    cat > "${stage_dir}/backup-manifest.json" <<EOF
{
  "project": "infiax-status-monitor",
  "version": "${ISM_VERSION}",
  "timestamp_utc": "${ts}",
  "hostname": "$(hostname 2>/dev/null || printf 'unknown')",
  "runtime_dir": "${rdir}"
}
EOF

    msg_info "Compressing backup archive: ${archive_name}..."
    tar -C "${stage_dir}" -czf "${archive_path}" backup-manifest.json config data
    rm -rf "${stage_dir}"
    chmod 600 "${archive_path}"

    local sha256_val
    sha256_val="$(compute_sha256 "${archive_path}")"
    printf '%s  %s\n' "${sha256_val}" "${archive_name}" > "${archive_path}.sha256"
    chmod 600 "${archive_path}.sha256"

    msg_info "Verifying backup archive integrity and SHA-256 checksum..."
    if ! verify_backup_archive "${archive_path}"; then
        rm -f "${archive_path}" "${archive_path}.sha256"
        msg_error "Backup verification failed! Archive removed."
        return 1
    fi

    local archive_size
    archive_size="$(du -h "${archive_path}" 2>/dev/null | awk '{print $1}')"
    msg_ok "Backup created and verified: ${archive_path} (${archive_size})"
    msg_ok "SHA-256 Checksum: ${sha256_val}"

    local retention
    retention="$(get_env_val "BACKUP_RETENTION_COUNT" "7" "${env_file}")"
    prune_old_backups "${backup_dir}" "${retention}"

    printf '%s\n' "${archive_path}" > "${backup_dir}/.latest_backup"
    chmod 600 "${backup_dir}/.latest_backup"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-create}" in
        list|--list)
            list_backups
            ;;
        verify|--verify)
            verify_backup_archive "${2:-}"
            ;;
        create|--create|*)
            create_backup
            ;;
    esac
fi
