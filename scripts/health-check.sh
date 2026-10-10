#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Health Checks & Guided Troubleshooting
# ==============================================================================
# Implements Menu Option 16 (Comprehensive Health Checks) and Menu Option 17
# (Guided Troubleshooting & Automated Root-Cause Diagnostics).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"
# shellcheck source=scripts/preflight.sh
source "${SCRIPT_DIR}/preflight.sh"

run_health_checks() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    local pass_cnt=0
    local warn_cnt=0
    local fail_cnt=0

    print_section "COMPREHENSIVE STACK HEALTH CHECKS"

    # 1. Configuration & Permission Check
    if [[ -f "${env_file}" ]]; then
        local perm=""
        if stat -c '%a' "${env_file}" >/dev/null 2>&1; then
            perm="$(stat -c '%a' "${env_file}")"
        elif stat -f '%Lp' "${env_file}" >/dev/null 2>&1; then
            perm="$(stat -f '%Lp' "${env_file}")"
        fi
        if [[ "${perm}" == "600" ]]; then
            msg_ok "Environment file (${env_file}) permissions are secure (0600)."
            pass_cnt=$(( pass_cnt + 1 ))
        else
            msg_warn "Environment file permissions are ${perm:-unknown} (fixing to 0600)."
            chmod 600 "${env_file}" 2>/dev/null || true
            warn_cnt=$(( warn_cnt + 1 ))
        fi
    else
        msg_warn "Environment file (${env_file}) not created yet."
        warn_cnt=$(( warn_cnt + 1 ))
    fi

    # 2. Container Runtime & Health Checks
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        local cname
        for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
            if docker inspect "${cname}" >/dev/null 2>&1; then
                local st hlth
                st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'unknown')"
                hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${cname}" 2>/dev/null || printf 'none')"
                if [[ "${st}" == "running" && ( "${hlth}" == "healthy" || "${hlth}" == "none" ) ]]; then
                    msg_ok "Container '${cname}' is running (health: ${hlth})."
                    pass_cnt=$(( pass_cnt + 1 ))
                elif [[ "${st}" == "running" && "${hlth}" == "starting" ]]; then
                    msg_warn "Container '${cname}' is running and still initializing (health: starting)."
                    warn_cnt=$(( warn_cnt + 1 ))
                else
                    msg_error "Container '${cname}' state='${st}', health='${hlth}'."
                    fail_cnt=$(( fail_cnt + 1 ))
                fi
            else
                msg_warn "Container '${cname}' is not deployed."
                warn_cnt=$(( warn_cnt + 1 ))
            fi
        done
    else
        msg_warn "Docker daemon is not running or inaccessible; container runtime checks skipped."
        warn_cnt=$(( warn_cnt + 1 ))
    fi

    # 3. Beszel Agent Unix Socket Check
    if [[ -S "${rdir}/data/beszel-socket/beszel.sock" ]]; then
        msg_ok "Beszel Agent Unix socket is active (${rdir}/data/beszel-socket/beszel.sock)."
        pass_cnt=$(( pass_cnt + 1 ))
    else
        msg_warn "Beszel Agent Unix socket not detected at ${rdir}/data/beszel-socket/beszel.sock."
        warn_cnt=$(( warn_cnt + 1 ))
    fi

    # 4. Internal Port Isolation Check (Ensure 3001, 8090, 45876 are NOT publicly exposed)
    local iport
    for iport in 3001 8090 45876; do
        local listener
        listener="$(check_port_listener "${iport}")"
        if [[ -z "${listener}" ]]; then
            msg_ok "Internal service port ${iport} is isolated (not bound on host network)."
            pass_cnt=$(( pass_cnt + 1 ))
        else
            msg_error "Security warning: internal port ${iport} is bound on host: ${listener}"
            fail_cnt=$(( fail_cnt + 1 ))
        fi
    done

    # 5. HTTPS Endpoint & Certificate Verification
    local status_domain beszel_domain
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    if command -v curl >/dev/null 2>&1; then
        local url
        for url in "https://${status_domain}" "https://${beszel_domain}"; do
            local http_code
            http_code="$(curl -fsSL -o /dev/null -w '%{http_code}' --max-time 8 "${url}" 2>/dev/null || printf '000')"
            if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
                msg_ok "HTTPS endpoint reachable and TLS valid: ${url} (HTTP ${http_code})"
                pass_cnt=$(( pass_cnt + 1 ))
            else
                msg_warn "HTTPS endpoint '${url}' returned HTTP ${http_code} (stack may not be deployed yet or DNS not propagated)."
                warn_cnt=$(( warn_cnt + 1 ))
            fi
        done
    fi

    # 6. SQLite Database Integrity Check
    if command -v sqlite3 >/dev/null 2>&1 && [[ -d "${rdir}/data" ]]; then
        local db
        while IFS= read -r db; do
            [[ -z "${db}" ]] && continue
            local chk
            chk="$(sqlite3 "${db}" "PRAGMA quick_check;" 2>/dev/null || printf 'failed')"
            if [[ "${chk}" == "ok" ]]; then
                msg_ok "SQLite database healthy: ${db#"${rdir}/"}"
                pass_cnt=$(( pass_cnt + 1 ))
            else
                msg_error "SQLite database integrity warning on ${db#"${rdir}/"}: ${chk}"
                fail_cnt=$(( fail_cnt + 1 ))
            fi
        done < <(find "${rdir}/data" -type f -name '*.db' 2>/dev/null)
    fi

    draw_line 56 "─"
    printf '  %sHealth Summary:%s %s%d Healthy%s | %s%d Warnings%s | %s%d Errors%s\n' \
        "${C_BOLD}" "${C_RESET}" \
        "${C_GREEN}" "${pass_cnt}" "${C_RESET}" \
        "${C_YELLOW}" "${warn_cnt}" "${C_RESET}" \
        "${C_RED}" "${fail_cnt}" "${C_RESET}"

    if (( fail_cnt > 0 )); then
        return 1
    fi
    return 0
}

run_troubleshooting_diagnostics() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local status_domain beszel_domain
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    print_section "AUTOMATED TROUBLESHOOTING & DIAGNOSTICS"

    printf '  %s1. HTTPS / Let'\''s Encrypt Certificate Diagnostics%s\n' "${C_BOLD}" "${C_RESET}"
    printf '     • Verify DNS A records for %s and %s match your VPS IPv4.\n' "${status_domain}" "${beszel_domain}"
    printf '     • Ensure no IPv6 AAAA records exist unless IPv6 is routed to Caddy.\n'
    printf '     • Ensure Oracle Cloud VCN Security List allows Ingress TCP 80 and TCP/UDP 443.\n\n'

    printf '  %s2. Oracle Cloud iptables & Docker Bridge Diagnostics%s\n' "${C_BOLD}" "${C_RESET}"
    if command -v iptables >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        local fwd_rules
        fwd_rules="$(iptables -S FORWARD 2>/dev/null || true)"
        local reject_line docker_line
        reject_line="$(printf '%s\n' "${fwd_rules}" | grep -n "REJECT" | head -n 1 | cut -d: -f1 || true)"
        docker_line="$(printf '%s\n' "${fwd_rules}" | grep -n "DOCKER" | head -n 1 | cut -d: -f1 || true)"
        if [[ -n "${reject_line}" && -n "${docker_line}" ]] && (( reject_line < docker_line )); then
            msg_warn "iptables FORWARD chain has a REJECT rule BEFORE the DOCKER chain! This happens if 'netfilter-persistent reload' ran after Docker started."
            msg_info "Remediation: Run 'sudo systemctl restart docker' so Docker places DOCKER-USER/DOCKER rules at the top of FORWARD."
        else
            msg_ok "iptables FORWARD chain ordering looks healthy."
        fi
    else
        printf '     • Run with sudo to inspect live iptables FORWARD chain ordering.\n'
    fi
    printf '\n'

    printf '  %s3. Beszel Agent Connectivity Diagnostics%s\n' "${C_BOLD}" "${C_RESET}"
    printf '     • In Beszel Hub UI (https://%s), the system Host/IP must be set to:\n' "${beszel_domain}"
    printf '       %s/beszel_socket/beszel.sock%s\n' "${C_GREEN}" "${C_RESET}"
    printf '     • Run Menu Option 05 (Configure Beszel Agent) to re-sync BESZEL_AGENT_KEY.\n\n'

    printf '  %s4. Low-Memory (OOM) Diagnostics%s\n' "${C_BOLD}" "${C_RESET}"
    if command -v dmesg >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        local oom_events
        oom_events="$(dmesg -T 2>/dev/null | grep -i -E 'out of memory|oom-kill|killed process' | tail -n 5 || true)"
        if [[ -n "${oom_events}" ]]; then
            msg_warn "Recent kernel OOM events detected:"
            printf '%s\n' "${oom_events}"
        else
            msg_ok "No kernel Out-Of-Memory (OOM) kills detected in dmesg."
        fi
    else
        printf '     • Check swap usage in Menu Option 01 (4 GiB swap recommended on 1 GiB RAM VPS).\n'
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-health}" in
        troubleshoot|--troubleshoot)
            run_troubleshooting_diagnostics
            ;;
        health|--health|*)
            run_health_checks
            ;;
    esac
fi
