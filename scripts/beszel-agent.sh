#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Beszel Agent Pairing & Configuration Manager
# ==============================================================================
# Manages secure pairing between Beszel Hub and Beszel Agent over the shared
# Unix socket (/beszel_socket/beszel.sock) and optional WebSocket token.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

detect_hub_public_key() {
    local rdir
    rdir="$(get_runtime_dir)"
    local pub_file="${rdir}/data/beszel/id_ed25519.pub"
    local priv_file="${rdir}/data/beszel/id_ed25519"
    local key=""

    if [[ -r "${pub_file}" ]]; then
        key="$(head -n 1 "${pub_file}" | tr -d '\r\n' || true)"
    elif [[ -r "${priv_file}" ]] && command -v ssh-keygen >/dev/null 2>&1; then
        key="$(ssh-keygen -y -f "${priv_file}" 2>/dev/null | head -n 1 | tr -d '\r\n' || true)"
    fi

    if [[ "${key}" == ssh-ed25519\ * ]]; then
        printf '%s\n' "${key}"
    else
        printf '\n'
    fi
}

auto_sync_beszel_key() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    ensure_env_file "${env_file}"

    local current_key
    current_key="$(get_env_val "BESZEL_AGENT_KEY" "" "${env_file}")"
    if [[ -n "${current_key}" ]]; then
        return 0
    fi

    local detected_key
    detected_key="$(detect_hub_public_key)"
    if [[ -n "${detected_key}" ]]; then
        set_env_val "BESZEL_AGENT_KEY" "${detected_key}" "${env_file}"
        msg_ok "Auto-populated BESZEL_AGENT_KEY from local Beszel Hub ED25519 key."
        return 0
    fi
    return 1
}

validate_beszel_ssh_key() {
    local key="${1:-}"
    if [[ -z "${key}" ]]; then
        return 1
    fi
    [[ "${key}" =~ ^ssh-(ed25519|rsa|ecdsa)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

configure_beszel_agent_interactive() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    ensure_env_file "${env_file}"

    local beszel_domain cur_key cur_token detected_key
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    cur_key="$(get_env_val "BESZEL_AGENT_KEY" "" "${env_file}")"
    cur_token="$(get_env_val "BESZEL_AGENT_TOKEN" "" "${env_file}")"
    detected_key="$(detect_hub_public_key)"

    print_section "CONFIGURE & PAIR BESZEL AGENT"

    printf '  %sGuided Pairing Workflow:%s\n' "${C_BOLD}" "${C_RESET}"
    printf '  1. Open Beszel Hub in your browser: %shttps://%s%s\n' "${C_CYAN}" "${beszel_domain}" "${C_RESET}"
    printf '  2. Sign in (or create your initial administrator account).\n'
    printf '  3. Click %s"+ Add System"%s in the top-right corner.\n' "${C_BOLD}" "${C_RESET}"
    printf '  4. Enter the following settings for this VPS:\n'
    printf '     • %sName%s      : %s\n' "${C_BOLD}" "${C_RESET}" "$(hostname 2>/dev/null || printf 'infiax-vps')"
    printf '     • %sHost / IP%s : %s/beszel_socket/beszel.sock%s\n' "${C_BOLD}" "${C_RESET}" "${C_GREEN}" "${C_RESET}"
    printf '  5. Copy the %sPublic Key%s (ssh-ed25519 ...) and %sToken%s from the dialog.\n\n' "${C_BOLD}" "${C_RESET}" "${C_BOLD}" "${C_RESET}"

    print_kv "Current Agent Key" "$(mask_secret "${cur_key}")"
    print_kv "Current Agent Token" "$(mask_secret "${cur_token}")"
    print_kv "Agent Listen Socket" "/beszel_socket/beszel.sock (shared volume, no public TCP port)"

    local default_key="${cur_key}"
    if [[ -z "${default_key}" && -n "${detected_key}" ]]; then
        default_key="${detected_key}"
        printf '\n'
        msg_info "Auto-detected Hub ED25519 public key from ${rdir}/data/beszel:"
        printf '  %s%s%s\n' "${C_DIM}" "${detected_key}" "${C_RESET}"
    fi

    printf '\n'
    local new_key=""
    while true; do
        if [[ -n "${default_key}" ]]; then
            new_key="$(prompt_input "Enter Beszel Public Key (press Enter to use current/detected key)" "${default_key}")"
        else
            new_key="$(prompt_input "Paste Beszel Public Key (starts with 'ssh-ed25519 ')" "")"
        fi

        if validate_beszel_ssh_key "${new_key}"; then
            break
        fi
        msg_error "Invalid SSH public key format. Must start with 'ssh-ed25519 ' followed by base64 key material."
    done

    local new_token=""
    new_token="$(prompt_input "Enter Beszel Agent Token (optional for Unix socket, required for WebSocket)" "${cur_token}")"

    set_env_val "BESZEL_AGENT_KEY" "${new_key}" "${env_file}"
    set_env_val "BESZEL_AGENT_TOKEN" "${new_token}" "${env_file}"
    set_env_val "BESZEL_AGENT_LISTEN" "/beszel_socket/beszel.sock" "${env_file}"
    set_env_val "BESZEL_HUB_URL" "https://${beszel_domain}" "${env_file}"

    msg_ok "Updated Beszel Agent configuration in ${env_file} (mode 0600)."

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        msg_info "Restarting beszel-agent container with updated credentials..."
        run_compose up -d beszel-agent
        sleep 2
        if [[ -S "${rdir}/data/beszel-socket/beszel.sock" ]]; then
            msg_ok "Verified Unix domain socket is active: ${rdir}/data/beszel-socket/beszel.sock"
        else
            msg_info "Waiting for beszel-agent socket initialization (check logs if system remains offline)."
        fi
    else
        msg_info "Docker is not currently active; changes will take effect when services start."
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-interactive}" in
        auto-sync|--auto-sync)
            auto_sync_beszel_key || true
            ;;
        *)
            configure_beszel_agent_interactive
            ;;
    esac
fi
