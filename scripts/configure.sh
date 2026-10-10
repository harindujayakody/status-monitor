#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Runtime Directory & Domain Configuration Manager
# ==============================================================================
# Manages /opt/infiax-status-monitor directory layout, .env generation, domain
# validation (rejecting underscores), DNS A/AAAA checks, and Caddy reloads.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/preflight.sh
source "${SCRIPT_DIR}/preflight.sh"

prepare_runtime_directories() {
    local target_dir="${1:-${INSTALL_DIR}}"
    print_section "PREPARING RUNTIME DIRECTORIES"

    mkdir -p \
        "${target_dir}/data/uptime-kuma" \
        "${target_dir}/data/beszel" \
        "${target_dir}/data/beszel-agent" \
        "${target_dir}/data/beszel-socket" \
        "${target_dir}/data/caddy/data" \
        "${target_dir}/data/caddy/config" \
        "${target_dir}/data/caddy/logs" \
        "${target_dir}/backups" \
        "${target_dir}/logs" \
        "${target_dir}/scripts" \
        "${target_dir}/docs"

    chmod 750 "${target_dir}/data" "${target_dir}/logs" 2>/dev/null || true
    chmod 700 "${target_dir}/backups" "${target_dir}/data/beszel-socket" 2>/dev/null || true

    # Copy project files if running from outside target_dir
    local src_root="${PROJECT_ROOT}"
    if [[ "$(cd "${src_root}" && pwd)" != "$(cd "${target_dir}" && pwd)" ]]; then
        msg_info "Syncing application definitions and scripts to ${target_dir}..."
        cp "${src_root}/compose.yaml" "${target_dir}/compose.yaml"
        cp "${src_root}/Caddyfile" "${target_dir}/Caddyfile"
        cp "${src_root}/.env.example" "${target_dir}/.env.example"
        cp "${src_root}/install.sh" "${target_dir}/install.sh"
        cp "${src_root}/monitor.sh" "${target_dir}/monitor.sh"
        cp "${src_root}/uninstall.sh" "${target_dir}/uninstall.sh"
        cp "${src_root}/scripts/"*.sh "${target_dir}/scripts/"
        if compgen -G "${src_root}/docs/*.md" >/dev/null; then
            cp "${src_root}/docs/"*.md "${target_dir}/docs/"
        fi
    fi

    chmod 755 "${target_dir}/install.sh" "${target_dir}/monitor.sh" "${target_dir}/uninstall.sh" "${target_dir}/scripts/"*.sh 2>/dev/null || true

    local env_file="${target_dir}/.env"
    if [[ ! -f "${env_file}" ]]; then
        cp "${target_dir}/.env.example" "${env_file}"
        chmod 600 "${env_file}"
        msg_ok "Initialized protected environment file: ${env_file} (mode 0600)"
    else
        chmod 600 "${env_file}"
        msg_ok "Preserved existing environment file: ${env_file} (mode 0600)"
    fi

    msg_ok "Runtime directory structure verified at ${target_dir}"
}

validate_stack_configs() {
    local rdir
    rdir="$(get_runtime_dir)"
    print_section "VALIDATING STACK CONFIGURATION"

    if [[ ! -f "${rdir}/compose.yaml" ]]; then
        msg_error "Missing compose.yaml in ${rdir}"
        return 1
    fi
    if [[ ! -f "${rdir}/Caddyfile" ]]; then
        msg_error "Missing Caddyfile in ${rdir}"
        return 1
    fi

    # Check balanced braces in Caddyfile
    local open_braces close_braces
    open_braces="$(tr -cd '{' < "${rdir}/Caddyfile" | wc -c | tr -d '[:space:]')"
    close_braces="$(tr -cd '}' < "${rdir}/Caddyfile" | wc -c | tr -d '[:space:]')"
    if [[ "${open_braces}" != "${close_braces}" ]] || (( open_braces == 0 )); then
        msg_error "Caddyfile syntax error: unbalanced braces (${open_braces} open vs ${close_braces} close)."
        return 1
    fi
    msg_ok "Caddyfile structure and brace balance verified."

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        if run_compose config -q >/dev/null 2>&1; then
            msg_ok "Docker Compose configuration ('docker compose config') is valid."
        else
            msg_error "Docker Compose validation failed."
            run_compose config || true
            return 1
        fi

        # Validate Caddyfile with Caddy binary if image is already pulled or container is running
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^infiax-caddy$'; then
            if docker exec infiax-caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
                msg_ok "Caddyfile validated using live Caddy engine."
            else
                msg_error "Caddyfile validation failed inside infiax-caddy container."
                return 1
            fi
        fi
    else
        msg_info "Docker CLI not active; skipped 'docker compose config' runtime check."
    fi
    return 0
}

configure_domains_interactive() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    ensure_env_file "${env_file}"

    print_section "CONFIGURE DOMAINS & TLS SETTINGS"

    local cur_status cur_beszel cur_email cur_ipv4
    cur_status="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    cur_beszel="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    cur_email="$(get_env_val "ACME_EMAIL" "admin@infiax.com" "${env_file}")"
    cur_ipv4="$(get_env_val "SERVER_IPV4" "${ISM_DEFAULT_SERVER_IPV4}" "${env_file}")"

    print_kv "Current Status Domain" "${cur_status}"
    print_kv "Current Beszel Domain" "${cur_beszel}"
    print_kv "Current ACME Email" "${cur_email}"
    print_kv "Expected Server IPv4" "${cur_ipv4}"
    printf '\n'
    msg_info "Note: Use hyphens (-), never underscores (_), in domain names (e.g., dev-monitor.infiax.com)."

    local new_status=""
    while true; do
        new_status="$(prompt_input "Enter Uptime Kuma domain" "${cur_status}")"
        if validate_domain "${new_status}"; then
            break
        fi
    done

    local new_beszel=""
    while true; do
        new_beszel="$(prompt_input "Enter Beszel Hub domain" "${cur_beszel}")"
        if ! validate_domain "${new_beszel}"; then
            continue
        fi
        if [[ "${new_beszel}" == "${new_status}" ]]; then
            msg_error "Beszel Hub domain must be distinct from Uptime Kuma domain (${new_status})."
            continue
        fi
        break
    done

    local new_email=""
    while true; do
        new_email="$(prompt_input "Enter ACME TLS notification email" "${cur_email}")"
        if validate_email "${new_email}"; then
            break
        fi
        msg_error "Invalid email address format: '${new_email}'."
    done

    local new_ipv4=""
    while true; do
        new_ipv4="$(prompt_input "Enter expected public IPv4 of this VPS" "${cur_ipv4}")"
        if validate_ipv4 "${new_ipv4}"; then
            break
        fi
        msg_error "Invalid IPv4 address: '${new_ipv4}'."
    done

    printf '\n'
    msg_info "Checking DNS records for ${new_status} and ${new_beszel}..."
    local d
    for d in "${new_status}" "${new_beszel}"; do
        local a_recs aaaa_recs
        a_recs="$(resolve_dns_a "${d}")"
        aaaa_recs="$(resolve_dns_aaaa "${d}")"
        if [[ -z "${a_recs}" ]]; then
            msg_warn "DNS A record for '${d}' was not found or DNS is unreachable."
        elif [[ " ${a_recs} " == *" ${new_ipv4} "* ]]; then
            msg_ok "DNS A record for '${d}' points to ${new_ipv4}."
        else
            msg_warn "DNS A record for '${d}' points to '${a_recs}' instead of '${new_ipv4}'."
        fi
        if [[ -n "${aaaa_recs}" ]]; then
            msg_warn "AAAA (IPv6) record detected on '${d}' (${aaaa_recs}). Ensure IPv6 is routed or remove the AAAA record before requesting Let's Encrypt certificates."
        fi
    done

    set_env_val "STATUS_DOMAIN" "${new_status}" "${env_file}"
    set_env_val "BESZEL_DOMAIN" "${new_beszel}" "${env_file}"
    set_env_val "BESZEL_APP_URL" "https://${new_beszel}" "${env_file}"
    set_env_val "BESZEL_HUB_URL" "https://${new_beszel}" "${env_file}"
    set_env_val "ACME_EMAIL" "${new_email}" "${env_file}"
    set_env_val "SERVER_IPV4" "${new_ipv4}" "${env_file}"

    msg_ok "Saved domain configuration to ${env_file} (permissions: 0600)."

    if command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^infiax-caddy$'; then
        if confirm_action "Apply updated domain configuration to running containers now?" "y"; then
            run_compose up -d caddy beszel beszel-agent
            msg_ok "Reloaded Caddy and Beszel services with new domain settings."
        fi
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-interactive}" in
        prepare|--prepare)
            prepare_runtime_directories "${2:-${INSTALL_DIR}}"
            ;;
        validate|--validate)
            validate_stack_configs
            ;;
        *)
            configure_domains_interactive
            ;;
    esac
fi
