#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Common Library & Terminal UI Primitives
# ==============================================================================
# Provides Infiax-branded (#0a66c2) ANSI/TrueColor formatting, safe .env
# parsing/updating, input validation, logging without ANSI codes, and signal
# handling. Compatible with Bash 3.2+ and Bash 5.x.
# ==============================================================================

if [[ -n "${_ISM_COMMON_LOADED:-}" ]]; then
    return 0
fi
readonly _ISM_COMMON_LOADED=1

set -euo pipefail

# --- Project Constants ---
export ISM_VERSION="1.0.0"
export ISM_BRAND_NAME="INFIAX STATUS MONITOR"
export ISM_REPO_URL="https://github.com/harindujayakody/status-monitor"
export ISM_DEFAULT_INSTALL_DIR="/opt/infiax-status-monitor"
export ISM_COMPOSE_PROJECT="infiax-status-monitor"
export ISM_DEFAULT_STATUS_DOMAIN="status.infiax.com"
export ISM_DEFAULT_BESZEL_DOMAIN="dev-monitor.infiax.com"
export ISM_DEFAULT_SERVER_IPV4="129.213.54.54"

# Resolve paths relative to this script
COMMON_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${COMMON_SCRIPT_DIR}/.." && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${ISM_DEFAULT_INSTALL_DIR}}"

# Determine active runtime directory (installed path if initialized, else repo root)
get_runtime_dir() {
    if [[ -f "${INSTALL_DIR}/compose.yaml" ]]; then
        printf '%s\n' "${INSTALL_DIR}"
    else
        printf '%s\n' "${PROJECT_ROOT}"
    fi
}

# --- Color & Terminal Initialization ---
C_RESET=""
C_BOLD=""
C_DIM=""
C_BRAND=""
C_CYAN=""
C_GREEN=""
C_YELLOW=""
C_RED=""
C_WHITE=""
C_GRAY=""

init_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
        C_RESET=$'\033[0m'
        C_BOLD=$'\033[1m'
        C_DIM=$'\033[2m'
        # Infiax brand primary color #0a66c2 (RGB: 10, 102, 194)
        if [[ "${COLORTERM:-}" == "truecolor" || "${COLORTERM:-}" == "24bit" ]]; then
            C_BRAND=$'\033[38;2;10;102;194m'
        else
            C_BRAND=$'\033[38;5;26m'
        fi
        C_CYAN=$'\033[36m'
        C_GREEN=$'\033[32m'
        C_YELLOW=$'\033[33m'
        C_RED=$'\033[31m'
        C_WHITE=$'\033[97m'
        C_GRAY=$'\033[90m'
    else
        C_RESET=""
        C_BOLD=""
        C_DIM=""
        C_BRAND=""
        C_CYAN=""
        C_GREEN=""
        C_YELLOW=""
        C_RED=""
        C_WHITE=""
        C_GRAY=""
    fi
}

init_colors

# --- Signal Handling ---
on_interrupt() {
    printf '\n%s[!] Operation interrupted by user (Ctrl+C). Exiting safely.%s\n' "${C_YELLOW}" "${C_RESET}" >&2
    exit 130
}

setup_traps() {
    trap on_interrupt INT TERM
}

# --- Logging (Plain text to log file, never ANSI sequences) ---
get_log_file() {
    local rdir
    rdir="$(get_runtime_dir)"
    local ldir="${ISM_LOG_DIR:-${rdir}/logs}"
    if mkdir -p "${ldir}" 2>/dev/null && [[ -w "${ldir}" ]]; then
        printf '%s/monitor.log\n' "${ldir}"
    else
        printf '/tmp/infiax-status-monitor.log\n'
    fi
}

log_event() {
    local level="$1"
    shift
    local message="$*"
    local logfile
    logfile="$(get_log_file)"
    local ts
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    # Strip any accidental control sequences before writing to disk
    local clean_msg
    clean_msg="$(printf '%s' "${message}" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')"
    printf '[%s] [%s] %s\n' "${ts}" "${level}" "${clean_msg}" >> "${logfile}" 2>/dev/null || true
}

# --- Terminal Width & Drawing Helpers ---
get_term_width() {
    local cols=72
    if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
        cols="$(tput cols 2>/dev/null || printf '72')"
    fi
    if [[ ! "${cols}" =~ ^[0-9]+$ ]] || (( cols < 60 )); then
        cols=68
    elif (( cols > 88 )); then
        cols=88
    fi
    printf '%s\n' "${cols}"
}

draw_line() {
    local width="${1:-68}"
    local char="${2:-─}"
    local i=0
    local out=""
    while (( i < width )); do
        out="${out}${char}"
        i=$(( i + 1 ))
    done
    printf '%s%s%s\n' "${C_BRAND}" "${out}" "${C_RESET}"
}

print_banner() {
    local subtitle="${1:-Self-Hosted VPS Monitoring & Management System}"
    printf '\n'
    printf '%s%s  I N F I A X%s\n' "${C_BOLD}" "${C_BRAND}" "${C_RESET}"
    printf '%s%s  STATUS MONITOR%s %s(v%s)%s\n' "${C_BOLD}" "${C_WHITE}" "${C_RESET}" "${C_GRAY}" "${ISM_VERSION}" "${C_RESET}"
    printf '  %s%s%s\n' "${C_DIM}" "${subtitle}" "${C_RESET}"
    draw_line 56 "─"
}

print_section() {
    local title="$1"
    printf '\n%s%s▸ %s%s\n' "${C_BOLD}" "${C_BRAND}" "${title}" "${C_RESET}"
    draw_line 56 "─"
}

print_kv() {
    local key="$1"
    local val="$2"
    printf '  %s%-24s%s : %s\n' "${C_DIM}" "${key}" "${C_RESET}" "${val}"
}

# --- Status Output Helpers ---
msg_info() {
    printf '%s[INFO]%s %s\n' "${C_BRAND}${C_BOLD}" "${C_RESET}" "$*"
    log_event "INFO" "$*"
}

msg_ok() {
    printf '%s[ OK ]%s %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*"
    log_event "OK" "$*"
}

msg_warn() {
    printf '%s[WARN]%s %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2
    log_event "WARN" "$*"
}

msg_error() {
    printf '%s[FAIL]%s %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2
    log_event "ERROR" "$*"
}

msg_step() {
    local step="$1"
    shift
    printf '\n%s[%s]%s %s%s%s\n' "${C_BRAND}${C_BOLD}" "${step}" "${C_RESET}" "${C_BOLD}" "$*" "${C_RESET}"
    log_event "STEP" "[${step}] $*"
}

# --- User Interaction Helpers ---
confirm_action() {
    local prompt="${1:-Are you sure you want to continue?}"
    local default_ans="${2:-n}"

    if [[ "${ISM_ASSUME_YES:-0}" == "1" ]]; then
        msg_info "Auto-confirmed (--yes): ${prompt}"
        return 0
    fi

    if [[ ! -t 0 ]]; then
        return 1
    fi

    local suffix="[y/N]"
    if [[ "${default_ans}" == "y" || "${default_ans}" == "Y" ]]; then
        suffix="[Y/n]"
    fi

    local reply=""
    printf '%s%s?%s %s %s: ' "${C_BOLD}" "${C_BRAND}" "${C_RESET}" "${prompt}" "${suffix}"
    read -r reply || return 1
    if [[ -z "${reply}" ]]; then
        reply="${default_ans}"
    fi
    case "${reply}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

prompt_input() {
    local prompt_text="$1"
    local default_val="${2:-}"
    local result=""

    if [[ -n "${default_val}" ]]; then
        printf '%s%s▸%s %s [%s%s%s]: ' "${C_BOLD}" "${C_BRAND}" "${C_RESET}" "${prompt_text}" "${C_CYAN}" "${default_val}" "${C_RESET}" >&2
    else
        printf '%s%s▸%s %s: ' "${C_BOLD}" "${C_BRAND}" "${C_RESET}" "${prompt_text}" >&2
    fi

    read -r result || true
    if [[ -z "${result}" ]]; then
        result="${default_val}"
    fi
    printf '%s\n' "${result}"
}

prompt_secret() {
    local prompt_text="$1"
    local result=""
    printf '%s%s▸%s %s (input hidden): ' "${C_BOLD}" "${C_BRAND}" "${C_RESET}" "${prompt_text}" >&2
    read -r -s result || true
    printf '\n' >&2
    printf '%s\n' "${result}"
}

pause_prompt() {
    if [[ -t 0 ]] && [[ "${ISM_NONINTERACTIVE:-0}" != "1" ]]; then
        printf '\n%sPress Enter to return to the menu...%s' "${C_DIM}" "${C_RESET}"
        read -r _ || true
    fi
}

mask_secret() {
    local secret="${1:-}"
    local len="${#secret}"
    if (( len == 0 )); then
        printf '(not configured)\n'
    elif (( len <= 8 )); then
        printf '********\n'
    else
        local prefix="${secret:0:4}"
        local suffix="${secret:$(( len - 4 )):4}"
        printf '%s...%s\n' "${prefix}" "${suffix}"
    fi
}

# --- Root & Environment Checks ---
require_root() {
    if [[ "${ISM_ALLOW_NON_ROOT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        msg_error "Root privileges are required for this operation."
        msg_info "Please re-run this command with sudo (e.g., sudo $0)."
        return 1
    fi
    return 0
}

# --- Safe .env Management ---
get_env_file() {
    local rdir
    rdir="$(get_runtime_dir)"
    printf '%s/.env\n' "${rdir}"
}

ensure_env_file() {
    local env_file="${1:-$(get_env_file)}"
    local rdir
    rdir="$(dirname "${env_file}")"
    if [[ ! -f "${env_file}" ]]; then
        if [[ -f "${rdir}/.env.example" ]]; then
            cp "${rdir}/.env.example" "${env_file}"
        elif [[ -f "${PROJECT_ROOT}/.env.example" ]]; then
            cp "${PROJECT_ROOT}/.env.example" "${env_file}"
        else
            touch "${env_file}"
        fi
    fi
    chmod 600 "${env_file}" 2>/dev/null || true
}

get_env_val() {
    local key="$1"
    local default_val="${2:-}"
    local env_file="${3:-$(get_env_file)}"

    if [[ ! -f "${env_file}" ]]; then
        printf '%s\n' "${default_val}"
        return 0
    fi

    local line=""
    line="$(grep -E "^[[:space:]]*${key}=" "${env_file}" 2>/dev/null | tail -n 1 || true)"
    if [[ -z "${line}" ]]; then
        printf '%s\n' "${default_val}"
        return 0
    fi

    local val="${line#*=}"
    # Strip surrounding single or double quotes if present
    if [[ "${val}" =~ ^\"(.*)\"$ ]]; then
        val="${BASH_REMATCH[1]}"
    elif [[ "${val}" =~ ^\'(.*)\'$ ]]; then
        val="${BASH_REMATCH[1]}"
    fi

    if [[ -z "${val}" && -n "${default_val}" ]]; then
        printf '%s\n' "${default_val}"
    else
        printf '%s\n' "${val}"
    fi
}

set_env_val() {
    local key="$1"
    local val="$2"
    local env_file="${3:-$(get_env_file)}"

    ensure_env_file "${env_file}"

    local tmp_file="${env_file}.tmp.$$"
    local found=0
    local formatted_val="${val}"

    # Quote values containing spaces
    if [[ "${val}" == *" "* ]]; then
        formatted_val="\"${val}\""
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^[[:space:]]*${key}= ]]; then
            printf '%s=%s\n' "${key}" "${formatted_val}" >> "${tmp_file}"
            found=1
        else
            printf '%s\n' "${line}" >> "${tmp_file}"
        fi
    done < "${env_file}"

    if (( found == 0 )); then
        printf '%s=%s\n' "${key}" "${formatted_val}" >> "${tmp_file}"
    fi

    mv "${tmp_file}" "${env_file}"
    chmod 600 "${env_file}" 2>/dev/null || true
}

load_env() {
    local env_file="${1:-$(get_env_file)}"
    if [[ ! -f "${env_file}" ]]; then
        return 0
    fi

    while IFS= read -r line || [[ -n "${line}" ]]; do
        # Skip empty lines and comments
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            local k="${BASH_REMATCH[1]}"
            local v="${BASH_REMATCH[2]}"
            if [[ "${v}" =~ ^\"(.*)\"$ ]]; then
                v="${BASH_REMATCH[1]}"
            elif [[ "${v}" =~ ^\'(.*)\'$ ]]; then
                v="${BASH_REMATCH[1]}"
            fi
            export "${k}=${v}"
        fi
    done < "${env_file}"
}

# --- Validation Functions ---
validate_domain() {
    local domain="${1:-}"
    if [[ -z "${domain}" ]]; then
        msg_error "Domain name cannot be empty."
        return 1
    fi
    if [[ "${domain}" == *"_"* ]]; then
        msg_error "Invalid domain '${domain}': underscores (_) are not permitted in hostnames or TLS certificates. Use hyphens (-) instead (e.g., dev-monitor.infiax.com)."
        return 1
    fi
    if [[ "${domain}" == *"://"* || "${domain}" == *"/"* ]]; then
        msg_error "Invalid domain '${domain}': enter the hostname only without http://, https://, or paths."
        return 1
    fi
    if (( ${#domain} > 253 )); then
        msg_error "Invalid domain '${domain}': exceeds 253 characters."
        return 1
    fi
    local regex='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,63}$'
    if [[ ! "${domain}" =~ ${regex} ]]; then
        msg_error "Invalid domain syntax: '${domain}'."
        return 1
    fi
    return 0
}

validate_ipv4() {
    local ip="${1:-}"
    local regex='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
    if [[ ! "${ip}" =~ ${regex} ]]; then
        return 1
    fi
    local IFS='.'
    # shellcheck disable=SC2206
    local octets=(${ip})
    local octet
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

validate_email() {
    local email="${1:-}"
    local regex='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
    [[ "${email}" =~ ${regex} ]]
}

# --- System Detection ---
detect_arch() {
    local raw_arch
    raw_arch="$(uname -m 2>/dev/null || printf 'unknown')"
    case "${raw_arch}" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf '%s\n' "${raw_arch}" ;;
    esac
}

detect_os_name() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${PRETTY_NAME:-${ID:-Linux}}" )
    elif command -v sw_vers >/dev/null 2>&1; then
        printf 'macOS %s\n' "$(sw_vers -productVersion 2>/dev/null || printf '')"
    else
        uname -s
    fi
}

detect_os_id() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${ID:-unknown}" )
    else
        uname -s | tr '[:upper:]' '[:lower:]'
    fi
}

detect_os_version() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        ( . /etc/os-release && printf '%s\n' "${VERSION_ID:-unknown}" )
    else
        printf 'unknown\n'
    fi
}

get_total_ram_mib() {
    if [[ -r /proc/meminfo ]]; then
        awk '/^MemTotal:/ { printf "%d\n", int($2 / 1024) }' /proc/meminfo
    elif command -v sysctl >/dev/null 2>&1; then
        local bytes
        bytes="$(sysctl -n hw.memsize 2>/dev/null || printf '0')"
        printf '%d\n' "$(( bytes / 1024 / 1024 ))"
    else
        printf '0\n'
    fi
}

get_used_ram_mib() {
    if [[ -r /proc/meminfo ]]; then
        awk '
            /^MemTotal:/ { total=$2 }
            /^MemAvailable:/ { avail=$2 }
            END {
                if (total > 0 && avail > 0) printf "%d\n", int((total - avail) / 1024);
                else printf "0\n";
            }
        ' /proc/meminfo
    else
        printf '0\n'
    fi
}

get_total_swap_mib() {
    if [[ -r /proc/meminfo ]]; then
        awk '/^SwapTotal:/ { printf "%d\n", int($2 / 1024) }' /proc/meminfo
    else
        printf '0\n'
    fi
}

get_free_disk_mb() {
    local target_path="${1:-/}"
    if [[ ! -e "${target_path}" ]]; then
        target_path="/"
    fi
    df -Pm "${target_path}" 2>/dev/null | awk 'NR==2 { print $4 }'
}

detect_public_ipv4() {
    local ip=""
    if command -v curl >/dev/null 2>&1; then
        ip="$(curl -4 -fsSL --max-time 4 https://icanhazip.com 2>/dev/null | tr -d '[:space:]' || true)"
        if ! validate_ipv4 "${ip}"; then
            ip="$(curl -4 -fsSL --max-time 4 https://api.ipify.org 2>/dev/null | tr -d '[:space:]' || true)"
        fi
    fi
    if validate_ipv4 "${ip}"; then
        printf '%s\n' "${ip}"
    else
        printf '\n'
    fi
}

# --- Docker Compose Helper ---
run_compose() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    if [[ -f "${env_file}" ]]; then
        docker compose --project-name "${ISM_COMPOSE_PROJECT}" \
            --project-directory "${rdir}" \
            --env-file "${env_file}" \
            -f "${rdir}/compose.yaml" "$@"
    else
        docker compose --project-name "${ISM_COMPOSE_PROJECT}" \
            --project-directory "${rdir}" \
            -f "${rdir}/compose.yaml" "$@"
    fi
}
