#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — System Information & Preflight Verification
# ==============================================================================
# Performs read-only system, resource, port, DNS (A + AAAA), and Oracle Cloud
# iptables firewall inspections without modifying system state.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

# --- DNS Resolution Helpers ---
resolve_dns_a() {
    local domain="$1"
    local records=""
    if command -v dig >/dev/null 2>&1; then
        records="$(dig +short +time=3 +tries=1 A "${domain}" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
        if [[ -z "${records}" ]]; then
            records="$(dig +short +time=3 +tries=1 A "${domain}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
        fi
    elif command -v getent >/dev/null 2>&1; then
        records="$(getent ahostsv4 "${domain}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
    elif command -v host >/dev/null 2>&1; then
        records="$(host -t A "${domain}" 2>/dev/null | awk '/has address/ {print $NF}' || true)"
    fi
    printf '%s\n' "${records}" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

resolve_dns_aaaa() {
    local domain="$1"
    local records=""
    if command -v dig >/dev/null 2>&1; then
        records="$(dig +short +time=3 +tries=1 AAAA "${domain}" @1.1.1.1 2>/dev/null | grep ':' || true)"
        if [[ -z "${records}" ]]; then
            records="$(dig +short +time=3 +tries=1 AAAA "${domain}" 2>/dev/null | grep ':' || true)"
        fi
    elif command -v host >/dev/null 2>&1; then
        records="$(host -t AAAA "${domain}" 2>/dev/null | awk '/has IPv6 address/ {print $NF}' || true)"
    fi
    printf '%s\n' "${records}" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# --- Menu Option 01: System Information ---
show_system_info() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    print_section "SYSTEM & ENVIRONMENT INFORMATION"

    local hostname_val os_name arch_val kernel_val uptime_val load_val
    hostname_val="$(hostname 2>/dev/null || printf 'unknown')"
    os_name="$(detect_os_name)"
    arch_val="$(detect_arch)"
    kernel_val="$(uname -r 2>/dev/null || printf 'unknown')"
    if [[ -r /proc/uptime ]]; then
        uptime_val="$(uptime -p 2>/dev/null || awk '{printf "%d hours", int($1/3600)}' /proc/uptime)"
    else
        uptime_val="$(uptime 2>/dev/null | sed 's/^.*up *//; s/, *[0-9]* user.*$//' || printf 'unknown')"
    fi
    if [[ -r /proc/loadavg ]]; then
        load_val="$(awk '{print $1 ", " $2 ", " $3}' /proc/loadavg)"
    else
        load_val="$(uptime 2>/dev/null | awk -F'load averages?: ' '{print $2}' || printf 'N/A')"
    fi

    local ram_total ram_used swap_total disk_free
    ram_total="$(get_total_ram_mib)"
    ram_used="$(get_used_ram_mib)"
    swap_total="$(get_total_swap_mib)"
    disk_free="$(get_free_disk_mb "${rdir}")"

    local status_domain beszel_domain conf_ipv4 pub_ipv4
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    conf_ipv4="$(get_env_val "SERVER_IPV4" "${ISM_DEFAULT_SERVER_IPV4}" "${env_file}")"
    pub_ipv4="$(detect_public_ipv4)"

    local docker_ver="Not installed"
    local compose_ver="Not installed"
    if command -v docker >/dev/null 2>&1; then
        docker_ver="$(docker --version 2>/dev/null | sed 's/Docker version //' || printf 'Installed')"
        compose_ver="$(docker compose version --short 2>/dev/null || printf 'Not available')"
    fi

    print_kv "Hostname" "${hostname_val}"
    print_kv "Operating System" "${os_name}"
    print_kv "Kernel Version" "${kernel_val}"
    print_kv "CPU Architecture" "${arch_val}"
    print_kv "System Uptime" "${uptime_val}"
    print_kv "Load Average" "${load_val}"
    print_kv "Memory (RAM)" "${ram_used} MiB used / ${ram_total} MiB total"
    print_kv "Swap Space" "${swap_total} MiB total"
    print_kv "Free Disk Space" "${disk_free} MiB available"
    print_kv "Configured VPS IPv4" "${conf_ipv4}"
    print_kv "Detected Public IPv4" "${pub_ipv4:-Unavailable (offline/sandboxed)}"
    print_kv "Docker Engine" "${docker_ver}"
    print_kv "Docker Compose" "${compose_ver}"
    print_kv "Runtime Directory" "${rdir}"
    print_kv "Uptime Kuma URL" "https://${status_domain}"
    print_kv "Beszel Hub URL" "https://${beszel_domain}"
}

# --- Port Inspection Helper ---
check_port_listener() {
    local port="$1"
    local listener=""
    if command -v ss >/dev/null 2>&1; then
        listener="$(ss -tulnp "sport = :${port}" 2>/dev/null | awk 'NR>1 {print $0}' || true)"
    elif command -v lsof >/dev/null 2>&1; then
        listener="$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {print $1, $2}' || true)"
    fi
    printf '%s\n' "${listener}"
}

# --- Menu Option 02 & Installer: Preflight Checks ---
run_preflight_checks() {
    local strict_mode="${1:-0}"
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    local pass_count=0
    local warn_count=0
    local fail_count=0

    print_section "PREFLIGHT & COMPATIBILITY CHECKS"

    # 1. Privilege check
    if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        msg_ok "Root privileges verified (UID 0)."
        pass_count=$(( pass_count + 1 ))
    else
        msg_warn "Running without root privileges (UID $(id -u)). Some firewall/socket inspections may be limited."
        warn_count=$(( warn_count + 1 ))
    fi

    # 2. Operating System check
    local os_id os_ver os_pretty
    os_id="$(detect_os_id)"
    os_ver="$(detect_os_version)"
    os_pretty="$(detect_os_name)"
    if [[ "${os_id}" == "ubuntu" ]]; then
        if [[ "${os_ver}" == "22.04" || "${os_ver}" == "24.04" ]]; then
            msg_ok "Supported Operating System detected: ${os_pretty}"
            pass_count=$(( pass_count + 1 ))
        else
            msg_warn "Ubuntu version '${os_ver}' detected (${os_pretty}). Primary target is Ubuntu 22.04 LTS."
            warn_count=$(( warn_count + 1 ))
        fi
    else
        if [[ "${ISM_ALLOW_UNSUPPORTED_OS:-0}" == "1" || "${strict_mode}" == "0" ]]; then
            msg_warn "Non-Ubuntu OS detected (${os_pretty}). Production target is Ubuntu Server 22.04 LTS."
            warn_count=$(( warn_count + 1 ))
        else
            msg_error "Unsupported OS: ${os_pretty}. Infiax Status Monitor targets Ubuntu Server 22.04 LTS."
            fail_count=$(( fail_count + 1 ))
        fi
    fi

    # 3. CPU Architecture check
    local arch
    arch="$(detect_arch)"
    if [[ "${arch}" == "amd64" || "${arch}" == "arm64" ]]; then
        msg_ok "Supported CPU architecture detected: ${arch}"
        pass_count=$(( pass_count + 1 ))
    else
        msg_error "Unsupported CPU architecture: ${arch} (expected amd64 or arm64)."
        fail_count=$(( fail_count + 1 ))
    fi

    # 4. RAM & Swap check (Low-memory VPS awareness)
    local ram_mib swap_mib
    ram_mib="$(get_total_ram_mib)"
    swap_mib="$(get_total_swap_mib)"
    if (( ram_mib >= 850 )); then
        msg_ok "System RAM: ${ram_mib} MiB (meets low-memory micro VPS baseline)."
        pass_count=$(( pass_count + 1 ))
    elif (( ram_mib > 0 )); then
        msg_warn "System RAM is very low (${ram_mib} MiB). Minimum recommended is ~950 MiB."
        warn_count=$(( warn_count + 1 ))
    fi

    if (( swap_mib >= 1024 )); then
        msg_ok "Swap configured: ${swap_mib} MiB (essential for low-memory stability)."
        pass_count=$(( pass_count + 1 ))
    elif (( ram_mib < 2048 )); then
        msg_warn "Swap is ${swap_mib} MiB on a <2 GiB RAM host. At least 2-4 GiB swap is strongly recommended."
        warn_count=$(( warn_count + 1 ))
    else
        msg_ok "Swap check skipped (host has ${ram_mib} MiB RAM)."
        pass_count=$(( pass_count + 1 ))
    fi

    # 5. Disk space check
    local free_mb
    free_mb="$(get_free_disk_mb "${rdir}")"
    if [[ "${free_mb}" =~ ^[0-9]+$ ]] && (( free_mb >= 3072 )); then
        msg_ok "Disk space available: ${free_mb} MiB (>= 3072 MiB required)."
        pass_count=$(( pass_count + 1 ))
    elif [[ "${free_mb}" =~ ^[0-9]+$ ]] && (( free_mb >= 1536 )); then
        msg_warn "Disk space is tight: ${free_mb} MiB free."
        warn_count=$(( warn_count + 1 ))
    else
        msg_error "Insufficient free disk space: ${free_mb:-0} MiB (at least 1536 MiB required)."
        fail_count=$(( fail_count + 1 ))
    fi

    # 6. Docker & Docker Compose availability
    if command -v docker >/dev/null 2>&1; then
        msg_ok "Docker CLI is installed: $(docker --version 2>/dev/null | head -n 1)"
        pass_count=$(( pass_count + 1 ))
        if docker compose version >/dev/null 2>&1; then
            msg_ok "Docker Compose v2 plugin available: $(docker compose version --short 2>/dev/null)"
            pass_count=$(( pass_count + 1 ))
        else
            msg_warn "Docker Compose v2 plugin not detected yet (can be installed by installer)."
            warn_count=$(( warn_count + 1 ))
        fi
    else
        msg_warn "Docker Engine is not installed yet (will be installed during Step 03 / install.sh)."
        warn_count=$(( warn_count + 1 ))
    fi

    # 7. Port availability check (80, 443, and internal ports 3001, 8090, 45876)
    local p80 p443
    p80="$(check_port_listener 80)"
    p443="$(check_port_listener 443)"
    if [[ -z "${p80}" ]]; then
        msg_ok "TCP Port 80 is free and ready for Caddy."
        pass_count=$(( pass_count + 1 ))
    elif [[ "${p80}" == *"caddy"* || "${p80}" == *"docker-proxy"* ]]; then
        msg_ok "TCP Port 80 is active (used by Caddy/Docker)."
        pass_count=$(( pass_count + 1 ))
    else
        msg_error "TCP Port 80 is occupied by another process: ${p80}"
        fail_count=$(( fail_count + 1 ))
    fi

    if [[ -z "${p443}" ]]; then
        msg_ok "TCP Port 443 is free and ready for Caddy."
        pass_count=$(( pass_count + 1 ))
    elif [[ "${p443}" == *"caddy"* || "${p443}" == *"docker-proxy"* ]]; then
        msg_ok "TCP Port 443 is active (used by Caddy/Docker)."
        pass_count=$(( pass_count + 1 ))
    else
        msg_error "TCP Port 443 is occupied by another process: ${p443}"
        fail_count=$(( fail_count + 1 ))
    fi

    local internal_port
    for internal_port in 3001 8090 45876; do
        local p_int
        p_int="$(check_port_listener "${internal_port}")"
        if [[ -z "${p_int}" ]]; then
            msg_ok "Internal port ${internal_port} is not publicly bound on host."
            pass_count=$(( pass_count + 1 ))
        else
            msg_warn "Port ${internal_port} has a host listener: ${p_int} (ensure it is not exposed publicly)."
            warn_count=$(( warn_count + 1 ))
        fi
    done

    # 8. Firewall & Oracle Cloud iptables inspection (Read-Only)
    if command -v ufw >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        local ufw_state
        ufw_state="$(ufw status 2>/dev/null | head -n 1 || true)"
        if [[ "${ufw_state}" == *"inactive"* ]]; then
            msg_ok "UFW is inactive (preserving native Oracle Cloud iptables rules)."
            pass_count=$(( pass_count + 1 ))
        else
            msg_warn "UFW is active (${ufw_state}). Ensure it does not conflict with Oracle Cloud iptables."
            warn_count=$(( warn_count + 1 ))
        fi
    fi

    if command -v iptables >/dev/null 2>&1 && [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        local ipt_rules
        ipt_rules="$(iptables -S 2>/dev/null || true)"
        if [[ "${ipt_rules}" == *"InstanceServices"* ]]; then
            msg_ok "Oracle Cloud 'InstanceServices' iptables chain is intact."
            pass_count=$(( pass_count + 1 ))
        else
            msg_info "No Oracle 'InstanceServices' chain detected (standard Linux iptables environment)."
        fi

        if [[ "${ipt_rules}" == *"--dport 22 "* ]]; then
            msg_ok "iptables INPUT allows TCP port 22 (SSH)."
            pass_count=$(( pass_count + 1 ))
        fi
        if [[ "${ipt_rules}" == *"--dport 80 "* && "${ipt_rules}" == *"--dport 443 "* ]]; then
            msg_ok "iptables INPUT allows TCP ports 80 and 443 (HTTP/HTTPS)."
            pass_count=$(( pass_count + 1 ))
        else
            msg_warn "Could not confirm explicit iptables ACCEPT rules for both TCP 80 and 443 in INPUT chain."
            warn_count=$(( warn_count + 1 ))
        fi

        if [[ -f /etc/iptables/rules.v4 ]]; then
            if grep -q "DOCKER" /etc/iptables/rules.v4 2>/dev/null; then
                msg_warn "/etc/iptables/rules.v4 contains transient DOCKER chains. Avoid running 'netfilter-persistent save' while Docker runs."
                warn_count=$(( warn_count + 1 ))
            else
                msg_ok "/etc/iptables/rules.v4 is clean (no transient Docker chains saved)."
                pass_count=$(( pass_count + 1 ))
            fi
        fi
    fi

    # 9. Domain Syntax & DNS Resolution Checks
    local status_domain beszel_domain expected_ip
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    expected_ip="$(get_env_val "SERVER_IPV4" "${ISM_DEFAULT_SERVER_IPV4}" "${env_file}")"

    local d
    for d in "${status_domain}" "${beszel_domain}"; do
        if validate_domain "${d}"; then
            msg_ok "Domain syntax valid: ${d}"
            pass_count=$(( pass_count + 1 ))

            local a_recs aaaa_recs
            a_recs="$(resolve_dns_a "${d}")"
            aaaa_recs="$(resolve_dns_aaaa "${d}")"

            if [[ -z "${a_recs}" ]]; then
                msg_warn "DNS A lookup for '${d}' returned no records (or DNS unreachable)."
                warn_count=$(( warn_count + 1 ))
            elif [[ " ${a_recs} " == *" ${expected_ip} "* ]]; then
                msg_ok "DNS A record for '${d}' resolves to expected IP (${expected_ip})."
                pass_count=$(( pass_count + 1 ))
            else
                msg_warn "DNS A record for '${d}' resolves to '${a_recs}' (expected '${expected_ip}')."
                warn_count=$(( warn_count + 1 ))
            fi

            if [[ -n "${aaaa_recs}" ]]; then
                msg_warn "Conflicting IPv6 AAAA record(s) found for '${d}': ${aaaa_recs}. Remove AAAA records if IPv6 is not routed on this VPS, or Let's Encrypt HTTP-01 validation may fail."
                warn_count=$(( warn_count + 1 ))
            else
                msg_ok "No conflicting IPv6 AAAA records detected for '${d}'."
                pass_count=$(( pass_count + 1 ))
            fi
        else
            fail_count=$(( fail_count + 1 ))
        fi
    done

    draw_line 56 "─"
    printf '  %sPreflight Summary:%s %s%d Passed%s | %s%d Warnings%s | %s%d Failed%s\n' \
        "${C_BOLD}" "${C_RESET}" \
        "${C_GREEN}" "${pass_count}" "${C_RESET}" \
        "${C_YELLOW}" "${warn_count}" "${C_RESET}" \
        "${C_RED}" "${fail_count}" "${C_RESET}"

    if (( fail_count > 0 )); then
        return 1
    fi
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-preflight}" in
        info|--info)
            show_system_info
            ;;
        preflight|--preflight|*)
            run_preflight_checks "${2:-0}"
            ;;
    esac
fi
