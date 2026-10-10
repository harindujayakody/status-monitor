#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Guided Telegram Setup & Live Alert Testing
# ==============================================================================
# Implements Menu Option 12 (Telegram Setup Guide & Credential Configuration)
# and Menu Option 13 (Send & Verify Live Telegram Test Notification).
# Never logs or exposes raw bot tokens in log files.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

validate_telegram_token() {
    local token="${1:-}"
    [[ "${token}" =~ ^[0-9]{6,15}:[A-Za-z0-9_-]{30,50}$ ]]
}

validate_telegram_chat_id() {
    local chat_id="${1:-}"
    [[ "${chat_id}" =~ ^-?[0-9]{5,20}$ || "${chat_id}" =~ ^@[A-Za-z0-9_]{4,64}$ ]]
}

discover_chat_id_from_bot() {
    local token="$1"
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        return 1
    fi
    local resp
    resp="$(curl -fsSL --max-time 8 "https://api.telegram.org/bot${token}/getUpdates" 2>/dev/null || true)"
    if [[ -z "${resp}" ]]; then
        return 1
    fi
    local cid
    cid="$(printf '%s' "${resp}" | jq -r '.result[-1].message.chat.id // .result[-1].channel_post.chat.id // empty' 2>/dev/null || true)"
    if [[ -n "${cid}" && "${cid}" != "null" ]]; then
        printf '%s\n' "${cid}"
        return 0
    fi
    return 1
}

telegram_setup_guide() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    ensure_env_file "${env_file}"

    local status_domain beszel_domain cur_token cur_chat
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"
    cur_token="$(get_env_val "TELEGRAM_BOT_TOKEN" "" "${env_file}")"
    cur_chat="$(get_env_val "TELEGRAM_CHAT_ID" "" "${env_file}")"

    print_section "TELEGRAM NOTIFICATIONS — GUIDED SETUP WORKFLOW"

    printf '  %sStep 1 — Create Your Telegram Bot via @BotFather:%s\n' "${C_BOLD}" "${C_RESET}"
    printf '    1. Open Telegram and message %s@BotFather%s.\n' "${C_CYAN}" "${C_RESET}"
    printf '    2. Send %s/newbot%s and follow the prompts to name your bot.\n' "${C_BOLD}" "${C_RESET}"
    printf '    3. Copy the HTTP API %sBot Token%s (format: 123456789:AAH...).\n' "${C_BOLD}" "${C_RESET}"
    printf '    4. Open a chat with your new bot and click %sStart%s (or send /start).\n\n' "${C_BOLD}" "${C_RESET}"

    printf '  %sStep 2 — Important Self-Hosted Monitoring Limitation:%s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}"
    printf '    A self-hosted VPS cannot send Telegram alerts if the VPS itself suffers\n'
    printf '    a complete power, kernel, or upstream network outage. Use an external\n'
    printf '    monitor (or secondary node) to watch https://%s for full\n' "${status_domain}"
    printf '    host-down detection.\n\n'

    print_kv "Saved Bot Token" "$(mask_secret "${cur_token}")"
    print_kv "Saved Chat ID" "${cur_chat:-(not configured)}"
    printf '\n'

    if ! confirm_action "Would you like to configure or update your Telegram credentials now?" "y"; then
        return 0
    fi

    local new_token=""
    while true; do
        new_token="$(prompt_secret "Enter Telegram Bot Token (leave blank to keep current)")"
        if [[ -z "${new_token}" && -n "${cur_token}" ]]; then
            new_token="${cur_token}"
        fi
        if validate_telegram_token "${new_token}"; then
            break
        fi
        msg_error "Invalid Telegram Bot Token format (expected digits:alphanumeric)."
    done

    # Attempt automatic Chat ID discovery via getUpdates
    local detected_chat=""
    msg_info "Checking Telegram API for recent messages to your bot..."
    if detected_chat="$(discover_chat_id_from_bot "${new_token}")"; then
        msg_ok "Auto-detected recent Chat ID from your bot: ${detected_chat}"
    else
        msg_info "Could not auto-detect Chat ID (send a message to your bot first, or enter Chat ID manually)."
    fi

    local default_chat="${detected_chat:-${cur_chat}}"
    local new_chat=""
    while true; do
        new_chat="$(prompt_input "Enter Telegram Chat ID" "${default_chat}")"
        if validate_telegram_chat_id "${new_chat}"; then
            break
        fi
        msg_error "Invalid Chat ID format (expected numeric ID such as 123456789 or -100123456789)."
    done

    set_env_val "TELEGRAM_BOT_TOKEN" "${new_token}" "${env_file}"
    set_env_val "TELEGRAM_CHAT_ID" "${new_chat}" "${env_file}"
    msg_ok "Telegram credentials saved securely to ${env_file} (mode 0600)."

    printf '\n  %sStep 3 — Native Application Integration Instructions:%s\n' "${C_BOLD}" "${C_RESET}"
    draw_line 56 "─"
    printf '  %sA) Uptime Kuma (https://%s):%s\n' "${C_BRAND}${C_BOLD}" "${status_domain}" "${C_RESET}"
    printf '     • Navigate to: Settings -> Notifications -> Setup Notification\n'
    printf '     • Notification Type : Telegram\n'
    printf '     • Friendly Name     : Infiax Telegram Alerts\n'
    printf '     • Bot Token         : (use your BotFather token)\n'
    printf '     • Chat ID           : %s\n' "${new_chat}"
    printf '     • Enable "Default enabled" & "Apply on all existing monitors" -> Test & Save.\n'
    printf '     • Triggers both Website DOWN and Website UP/Recovery notifications.\n\n'

    printf '  %sB) Beszel Hub (https://%s):%s\n' "${C_BRAND}${C_BOLD}" "${beszel_domain}" "${C_RESET}"
    printf '     • Navigate to: Settings -> Notifications\n'
    printf '     • Add the following Shoutrrr URL format:\n'
    printf '       %stelegram://<YOUR_BOT_TOKEN>@telegram?chats=%s%s\n' "${C_CYAN}" "${new_chat}" "${C_RESET}"
    printf '     • Click the bell icon on your VPS row in the dashboard to enable alerts for:\n'
    printf '       CPU, Memory, Disk usage, Bandwidth, Status (Up/Down), and Temperature.\n\n'

    if confirm_action "Send a live test notification to Telegram now?" "y"; then
        send_telegram_test_notification
    fi
}

send_telegram_test_notification() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    print_section "TEST TELEGRAM NOTIFICATIONS"

    local token chat_id status_domain beszel_domain
    token="$(get_env_val "TELEGRAM_BOT_TOKEN" "" "${env_file}")"
    chat_id="$(get_env_val "TELEGRAM_CHAT_ID" "" "${env_file}")"
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    if [[ -z "${token}" || -z "${chat_id}" ]]; then
        msg_error "Telegram Bot Token or Chat ID is not configured in ${env_file}."
        msg_info "Please run Menu Option 12 (Telegram Setup Guide) first."
        return 1
    fi

    local host_str ts_str
    host_str="$(hostname 2>/dev/null || printf 'infiax-vps')"
    ts_str="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    local text_payload
    text_payload="✅ *Infiax Status Monitor — Test Notification*

*Host:* \`${host_str}\`
*Time:* \`${ts_str}\`
*Uptime Kuma:* https://${status_domain}
*Beszel Hub:* https://${beszel_domain}

Telegram alert delivery is operational."

    msg_info "Sending test message to Chat ID '${chat_id}' via Telegram Bot API..."

    local response=""
    response="$(curl -fsSL --max-time 10 -X POST \
        "https://api.telegram.org/bot${token}/sendMessage" \
        -d "chat_id=${chat_id}" \
        -d "parse_mode=Markdown" \
        --data-urlencode "text=${text_payload}" 2>/dev/null || true)"

    if [[ "${response}" == *'"ok":true'* ]]; then
        msg_ok "Telegram test notification delivered and verified by Telegram API!"
        return 0
    else
        msg_error "Failed to deliver Telegram test notification. Verify your Bot Token, Chat ID, and outbound HTTPS connectivity."
        return 1
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-guide}" in
        test|--test)
            send_telegram_test_notification
            ;;
        guide|--guide|*)
            telegram_setup_guide
            ;;
    esac
fi
