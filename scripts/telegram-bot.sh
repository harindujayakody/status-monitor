#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Interactive Telegram Bot, Alert Watcher & Daily Report
# ==============================================================================
# Features:
#   1. Sri Lanka Timezone (Asia/Colombo / SLST) across all messages & reports.
#   2. Unified message format covering Uptime Kuma websites + all 6 Beszel
#      notification categories (Status, CPU, Memory, Disk, Network Loss,
#      Container Health).
#   3. Real-time state-change watcher for Uptime Kuma & Beszel alerts so every
#      notification uses the unified Infiax message format.
#   4. Automated 9:00 PM (Asia/Colombo) Everyday Full Report via systemd timer.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

export TZ="Asia/Colombo"

# --- Sri Lanka Timestamp Helper ---
get_sl_timestamp() {
    TZ="Asia/Colombo" date '+%Y-%m-%d • %I:%M:%S %p (SLST)'
}

# --- Host Uptime & Load Helpers ---
get_system_uptime() {
    if [[ -r /proc/uptime ]]; then
        uptime -p 2>/dev/null | sed 's/^up //' || awk '{printf "%d hours", int($1/3600)}' /proc/uptime
    else
        uptime 2>/dev/null | sed 's/^.*up *//; s/, *[0-9]* user.*$//' || printf 'online'
    fi
}

get_load_average() {
    if [[ -r /proc/loadavg ]]; then
        awk '{print $1 " / " $2 " / " $3}' /proc/loadavg
    else
        uptime 2>/dev/null | awk -F'load averages?: ' '{print $2}' || printf '0.00'
    fi
}

# --- Visual Bar Helper (10 blocks, mobile-friendly on iOS/Android) ---
make_bar() {
    local pct="${1:-0}"
    if (( pct < 0 )); then pct=0; fi
    if (( pct > 100 )); then pct=100; fi
    local filled=$(( (pct + 5) / 10 ))
    if (( filled > 10 )); then filled=10; fi
    local empty=$(( 10 - filled ))
    local bar=""
    local i
    for (( i = 0; i < filled; i++ )); do bar="${bar}█"; done
    for (( i = 0; i < empty; i++ )); do bar="${bar}░"; done
    printf '%s' "${bar}"
}

# --- Status Dot Helper (80% threshold matching Beszel alert rules) ---
metric_badge() {
    local val="${1:-0}"
    local warn_at="${2:-65}"
    local crit_at="${3:-80}"
    if (( val >= crit_at )); then
        printf '🔴'
    elif (( val >= warn_at )); then
        printf '🟡'
    else
        printf '🟢'
    fi
}

# --- Collect Live CPU Usage Percentage (Integer 0..100) ---
get_cpu_pct() {
    if [[ -r /proc/stat ]]; then
        local l1 l2
        l1="$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)"
        sleep 0.3
        l2="$(awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat)"
        awk -v a="${l1}" -v b="${l2}" 'BEGIN {
            split(a, s1, " "); split(b, s2, " ");
            t1 = s1[1]+s1[2]+s1[3]+s1[4]+s1[5]+s1[6]+s1[7];
            t2 = s2[1]+s2[2]+s2[3]+s2[4]+s2[5]+s2[6]+s2[7];
            id1 = s1[4] + s1[5]; id2 = s2[4] + s2[5];
            dt = t2 - t1; did = id2 - id1;
            if (dt <= 0) { print 0; exit }
            printf "%d\n", int(((dt - did) * 100) / dt + 0.5);
        }'
    else
        printf '0\n'
    fi
}

# --- Collect Live Disk Usage Percentage & GiB ---
get_disk_summary() {
    local rdir
    rdir="$(get_runtime_dir)"
    df -Pm "${rdir}" 2>/dev/null | awk 'NR==2 {
        total_gb = $2 / 1024;
        used_gb = $3 / 1024;
        pct = int(($3 * 100) / $2 + 0.5);
        printf "%d|%.1f|%.1f\n", pct, used_gb, total_gb;
    }'
}

# --- Collect Live Network Ping Loss & Latency to 1.1.1.1 ---
get_network_ping_summary() {
    local out loss rtt
    out="$(ping -c 3 -W 2 -q 1.1.1.1 2>/dev/null || true)"
    loss="$(printf '%s' "${out}" | awk -F',' '/packet loss/ {gsub(/[^0-9]/,"",$3); print $3}' || true)"
    rtt="$(printf '%s' "${out}" | awk -F'/' '/rtt|round-trip/ {print $5}' || true)"
    [[ -z "${loss}" ]] && loss="0"
    [[ -z "${rtt}" ]] && rtt="1.2"
    printf '%s|%s\n' "${loss}" "${rtt}"
}

# --- Query Uptime Kuma Monitored Websites from SQLite ---
get_uptime_kuma_monitors_summary() {
    local rdir
    rdir="$(get_runtime_dir)"
    local kuma_db="${rdir}/data/uptime-kuma/kuma.db"
    if [[ ! -r "${kuma_db}" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
        printf '🟢 <b>Uptime Kuma</b> — Active\n'
        return 0
    fi

    local rows
    rows="$(sqlite3 -separator '|' "${kuma_db}" "
        SELECT
            m.name,
            COALESCE(h.status, 1),
            COALESCE(h.ping, 0),
            COALESCE((SELECT ROUND(AVG(status)*100, 1) FROM heartbeat WHERE monitor_id = m.id AND time >= datetime('now', '-24 hours')), 100.0)
        FROM monitor m
        LEFT JOIN heartbeat h ON h.id = (SELECT id FROM heartbeat WHERE monitor_id = m.id ORDER BY time DESC LIMIT 1)
        WHERE m.active = 1;
    " 2>/dev/null || true)"

    if [[ -z "${rows}" ]]; then
        printf '🟢 <b>Uptime Kuma</b> — Ready (No active monitors)\n'
        return 0
    fi

    local line name st ping_ms up24 icon st_txt
    while IFS='|' read -r name st ping_ms up24; do
        [[ -z "${name}" ]] && continue
        if [[ "${st}" == "1" ]]; then
            icon="🟢"
            st_txt="UP"
        elif [[ "${st}" == "0" ]]; then
            icon="🔴"
            st_txt="DOWN"
        else
            icon="🟡"
            st_txt="PENDING"
        fi
        printf '%s <b>%s:</b> <code>%s</code> • <code>%s ms</code> <i>(%s%% 24h)</i>\n' \
            "${icon}" "${name}" "${st_txt}" "${ping_ms}" "${up24}"
    done <<< "${rows}"
}

# --- Unified All-Notifications Card Generator ---
# Used by:
#   - /status (Live Status)
#   - /report & 9:00 PM Daily Report
#   - Real-time Alert Trigger / Recovery Notifications
format_unified_notification_card() {
    local header_title="${1:-🛡️ <b>INFIAX STATUS MONITOR</b>}"
    local event_banner="${2:-}"

    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local status_domain beszel_domain
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    local host_name uptime_str load_str ts_str
    host_name="$(hostname 2>/dev/null || printf 'infiax-vps')"
    uptime_str="$(get_system_uptime)"
    load_str="$(get_load_average)"
    ts_str="$(get_sl_timestamp)"

    local cpu_pct ram_used ram_total ram_pct
    cpu_pct="$(get_cpu_pct)"
    ram_used="$(get_used_ram_mib)"
    ram_total="$(get_total_ram_mib)"
    ram_pct=0
    if (( ram_total > 0 )); then
        ram_pct=$(( (ram_used * 100) / ram_total ))
    fi

    local swap_used=0 swap_total=0 swap_pct=0
    if [[ -r /proc/meminfo ]]; then
        swap_total="$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo)"
        local swap_free
        swap_free="$(awk '/^SwapFree:/ {print int($2/1024)}' /proc/meminfo)"
        swap_used=$(( swap_total - swap_free ))
        if (( swap_total > 0 )); then
            swap_pct=$(( (swap_used * 100) / swap_total ))
        fi
    fi

    local disk_info disk_pct disk_used disk_total
    disk_info="$(get_disk_summary)"
    disk_pct="${disk_info%%|*}"
    local disk_rest="${disk_info#*|}"
    disk_used="${disk_rest%%|*}"
    disk_total="${disk_rest#*|}"

    local net_info net_loss net_rtt
    net_info="$(get_network_ping_summary)"
    net_loss="${net_info%%|*}"
    net_rtt="${net_info#*|}"

    local cpu_icon ram_icon disk_icon net_icon
    cpu_icon="$(metric_badge "${cpu_pct}" 65 80)"
    ram_icon="$(metric_badge "${ram_pct}" 65 80)"
    disk_icon="$(metric_badge "${disk_pct}" 65 80)"
    net_icon="$(metric_badge "${net_loss}" 5 10)"

    # Collect Container Health & Memory
    local stats_raw
    stats_raw="$(docker stats --no-stream --format '{{.Name}}|{{.MemUsage}}' 2>/dev/null || true)"

    local healthy_cnt=0
    local total_cnt=4
    local container_lines=""
    local cname
    for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
        local st hlth c_icon mem_short
        st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'stopped')"
        hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "${cname}" 2>/dev/null || printf 'missing')"
        if [[ "${st}" == "running" && "${hlth}" == "healthy" ]]; then
            healthy_cnt=$(( healthy_cnt + 1 ))
            c_icon="🟢"
        elif [[ "${st}" == "running" ]]; then
            c_icon="🟡"
        else
            c_icon="🔴"
        fi
        mem_short="$(printf '%s\n' "${stats_raw}" | awk -F'|' -v c="${cname}" '$1==c {split($2,a,"/"); gsub(/[[:space:]]+/,"",a[1]); print a[1]}')"
        [[ -z "${mem_short}" ]] && mem_short="N/A"
        local short_name="${cname#infiax-}"
        container_lines="${container_lines}• ${c_icon} <code>${short_name}</code>: ${hlth} <i>(${mem_short})</i>
"
    done

    local cont_badge="🟢"
    if (( healthy_cnt < total_cnt )); then
        cont_badge="🔴"
    fi

    local overall_badge="🟢 <b>ALL SYSTEMS OPERATIONAL</b>"
    if (( healthy_cnt < total_cnt || cpu_pct >= 80 || ram_pct >= 80 || disk_pct >= 80 || net_loss >= 10 )); then
        overall_badge="🔴 <b>ALERT THRESHOLD EXCEEDED</b>"
    fi
    if [[ -n "${event_banner}" ]]; then
        overall_badge="${event_banner}"
    fi

    local kuma_summary
    kuma_summary="$(get_uptime_kuma_monitors_summary)"

    cat <<EOF
${header_title}
${overall_badge}
────────────────

🌐 <b>Website Monitors</b>
${kuma_summary}
🖥️ <b>1. System Status</b> <i>(Alert &gt; 10m down)</i>
🟢 <b>ONLINE</b> • <code>${host_name}</code>
• Uptime: <code>${uptime_str}</code>
• Load: <code>${load_str}</code>

${cpu_icon} <b>2. CPU Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${cpu_pct}")</code> <b>${cpu_pct}%</b>

${ram_icon} <b>3. Memory Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${ram_pct}")</code> <b>${ram_pct}%</b>
• RAM: <code>${ram_used} MiB / ${ram_total} MiB</code>
• Swap: <code>${swap_used} MiB / ${swap_total} MiB (${swap_pct}%)</code>

${disk_icon} <b>4. Disk Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${disk_pct}")</code> <b>${disk_pct}%</b>
• Used: <code>${disk_used} GB / ${disk_total} GB</code>

${net_icon} <b>5. Network Monitor Loss</b> <i>(Alert &gt; 10%)</i>
• Cloudflare (1.1.1.1): <code>${net_loss}% loss</code> • <code>${net_rtt} ms</code>

${cont_badge} <b>6. Container Health</b> <i>(${healthy_cnt}/${total_cnt} Healthy)</i>
${container_lines}
🔗 <a href="https://${status_domain}">Status Page</a>  •  <a href="https://${beszel_domain}">Beszel Hub</a>
🕒 <i>${ts_str}</i>
EOF
}

# --- Format Commands ---
format_msg_status() {
    format_unified_notification_card "🛡️ <b>INFIAX STATUS MONITOR</b>"
}

format_msg_daily_report() {
    local rdir
    rdir="$(get_runtime_dir)"
    local beszel_db="${rdir}/data/beszel/data.db"
    local incidents_24h=0
    if [[ -r "${beszel_db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
        incidents_24h="$(sqlite3 "${beszel_db}" "SELECT COUNT(*) FROM alerts_history WHERE created >= datetime('now', '-24 hours');" 2>/dev/null || printf '0')"
    fi

    local banner="🟢 <b>24H SUMMARY: ${incidents_24h} ALERTS TRIGGERED</b>"
    if (( incidents_24h > 0 )); then
        banner="🟡 <b>24H SUMMARY: ${incidents_24h} ALERT(S) LOGGED</b>"
    fi
    format_unified_notification_card "📅 <b>DAILY 9:00 PM FULL REPORT</b>" "${banner}"
}

format_msg_metrics() {
    format_unified_notification_card "⚡ <b>RESOURCE TELEMETRY REPORT</b>"
}

format_msg_containers() {
    format_unified_notification_card "🐳 <b>CONTAINER HEALTH REPORT</b>"
}

format_msg_network() {
    format_unified_notification_card "🌐 <b>NETWORK &amp; UPTIME REPORT</b>"
}

format_msg_alerts() {
    format_unified_notification_card "🔔 <b>ALL NOTIFICATION RULES CHECK</b>"
}

format_msg_help() {
    cat <<'EOF'
🤖 <b>INFIAX MONITOR BOT</b>
────────────────

📊 /status — Live Full Status (All Notifications)
📅 /report — Daily 9:00 PM Full Report
⚡ /metrics — CPU, RAM &amp; Disk
🐳 /containers — Container Health
🌐 /network — Website &amp; Ping Status
🔔 /alerts — Alert Rules Check
EOF
}

# --- Register Premade Slash Commands with Telegram API (setMyCommands) ---
register_bot_commands() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local token
    token="$(get_env_val "TELEGRAM_BOT_TOKEN" "" "${env_file}")"

    if [[ -z "${token}" ]]; then
        msg_error "TELEGRAM_BOT_TOKEN is not set in ${env_file}."
        return 1
    fi

    local commands_json
    commands_json='{"commands":[
      {"command":"status","description":"📊 Server Status"},
      {"command":"report","description":"📅 Full Report"},
      {"command":"metrics","description":"⚡ CPU, RAM & Disk"},
      {"command":"containers","description":"🐳 Containers"},
      {"command":"network","description":"🌐 Network Ping"},
      {"command":"alerts","description":"🔔 Alert Rules"}
    ]}'

    local resp
    resp="$(curl -fsSL --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -d "${commands_json}" \
        "https://api.telegram.org/bot${token}/setMyCommands" 2>/dev/null || true)"

    if [[ "${resp}" == *'"ok":true'* ]]; then
        msg_ok "Registered simplified Telegram Menu commands (/status, /report, /metrics, /containers, /network, /alerts)."
        return 0
    else
        msg_error "Failed to register Telegram slash commands via setMyCommands."
        return 1
    fi
}

# --- Send Clean Telegram Message ---
send_bot_reply() {
    local token="$1"
    local chat_id="$2"
    local text_html="$3"
    local edit_msg_id="${4:-}"

    if [[ -n "${edit_msg_id}" ]]; then
        curl -fsSL --max-time 10 -X POST \
            "https://api.telegram.org/bot${token}/editMessageText" \
            -d "chat_id=${chat_id}" \
            -d "message_id=${edit_msg_id}" \
            -d "parse_mode=HTML" \
            -d "disable_web_page_preview=true" \
            --data-urlencode "text=${text_html}" >/dev/null 2>&1 || true
    else
        curl -fsSL --max-time 10 -X POST \
            "https://api.telegram.org/bot${token}/sendMessage" \
            -d "chat_id=${chat_id}" \
            -d "parse_mode=HTML" \
            -d "disable_web_page_preview=true" \
            --data-urlencode "text=${text_html}" >/dev/null 2>&1 || true
    fi
}

# --- Route Command to Formatter ---
dispatch_bot_command() {
    local cmd="$1"
    cmd="${cmd%%@*}"
    case "${cmd}" in
        /status|cmd_status)
            format_msg_status
            ;;
        /report|/daily|cmd_report)
            format_msg_daily_report
            ;;
        /metrics|/resources|cmd_metrics)
            format_msg_metrics
            ;;
        /containers|/docker|cmd_containers)
            format_msg_containers
            ;;
        /network|/ping|cmd_network)
            format_msg_network
            ;;
        /alerts|cmd_alerts)
            format_msg_alerts
            ;;
        /start|/help|cmd_help|*)
            format_msg_help
            ;;
    esac
}

# --- Check for Real-Time Alert State Changes (Beszel + Uptime Kuma) ---
# Sends a unified formatted notification card whenever any Uptime Kuma website
# or Beszel alert changes state (Triggered <-> Resolved).
check_and_notify_alert_transitions() {
    local token="$1"
    local chat_id="$2"
    local rdir
    rdir="$(get_runtime_dir)"
    local state_dir="${rdir}/data/beszel-agent"
    mkdir -p "${state_dir}" 2>/dev/null || true
    local prev_file="${state_dir}/.alert_state_snapshot"

    local current_state=""
    local beszel_db="${rdir}/data/beszel/data.db"
    local kuma_db="${rdir}/data/uptime-kuma/kuma.db"

    if [[ -r "${beszel_db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
        local b_rows
        b_rows="$(sqlite3 -separator ':' "${beszel_db}" "SELECT 'BESZEL_' || name, triggered FROM alerts ORDER BY name;" 2>/dev/null || true)"
        current_state="${current_state}${b_rows}"$'\n'
    fi

    if [[ -r "${kuma_db}" ]] && command -v sqlite3 >/dev/null 2>&1; then
        local k_rows
        k_rows="$(sqlite3 -separator ':' "${kuma_db}" "
            SELECT 'KUMA_' || m.name, COALESCE(h.status, 1)
            FROM monitor m
            LEFT JOIN heartbeat h ON h.id = (SELECT id FROM heartbeat WHERE monitor_id = m.id ORDER BY time DESC LIMIT 1)
            WHERE m.active = 1
            ORDER BY m.id;
        " 2>/dev/null || true)"
        current_state="${current_state}${k_rows}"$'\n'
    fi

    if [[ ! -f "${prev_file}" ]]; then
        printf '%s' "${current_state}" > "${prev_file}"
        return 0
    fi

    local prev_state
    prev_state="$(cat "${prev_file}" 2>/dev/null || true)"
    if [[ "${current_state}" == "${prev_state}" ]]; then
        return 0
    fi

    # Detect which specific item changed
    local key val old_val
    while IFS=':' read -r key val; do
        [[ -z "${key}" ]] && continue
        old_val="$(printf '%s\n' "${prev_state}" | awk -F':' -v k="${key}" '$1==k {print $2}' | head -n 1)"
        [[ -z "${old_val}" ]] && continue
        if [[ "${val}" != "${old_val}" ]]; then
            local html_alert=""
            if [[ "${key}" == BESZEL_* ]]; then
                local aname="${key#BESZEL_}"
                if [[ "${val}" == "1" ]]; then
                    html_alert="$(format_unified_notification_card "🚨 <b>INFIAX ALERT TRIGGERED</b>" "🔴 <b>${aname} THRESHOLD EXCEEDED</b>")"
                else
                    html_alert="$(format_unified_notification_card "✅ <b>INFIAX ALERT RESOLVED</b>" "🟢 <b>${aname} RECOVERED TO NORMAL</b>")"
                fi
            elif [[ "${key}" == KUMA_* ]]; then
                local mname="${key#KUMA_}"
                if [[ "${val}" == "0" ]]; then
                    html_alert="$(format_unified_notification_card "🚨 <b>WEBSITE DOWN ALERT</b>" "🔴 <b>${mname} IS UNREACHABLE</b>")"
                elif [[ "${val}" == "1" && "${old_val}" == "0" ]]; then
                    html_alert="$(format_unified_notification_card "✅ <b>WEBSITE RECOVERED</b>" "🟢 <b>${mname} IS BACK ONLINE</b>")"
                fi
            fi
            if [[ -n "${html_alert}" ]]; then
                send_bot_reply "${token}" "${chat_id}" "${html_alert}"
            fi
        fi
    done <<< "${current_state}"

    printf '%s' "${current_state}" > "${prev_file}"
}

# --- Long-Polling Bot Daemon ---
run_bot_daemon() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"

    local token allowed_chat
    token="$(get_env_val "TELEGRAM_BOT_TOKEN" "" "${env_file}")"
    allowed_chat="$(get_env_val "TELEGRAM_CHAT_ID" "" "${env_file}")"

    if [[ -z "${token}" || -z "${allowed_chat}" ]]; then
        msg_error "TELEGRAM_BOT_TOKEN and TELEGRAM_CHAT_ID must be configured in ${env_file}."
        exit 1
    fi

    register_bot_commands || true
    msg_info "Starting Infiax Telegram Bot long-polling responder (TZ=Asia/Colombo) for Chat ID ${allowed_chat}..."

    local offset=0
    local init_resp
    init_resp="$(curl -fsSL --max-time 10 -K - <<<"url = \"https://api.telegram.org/bot${token}/getUpdates?timeout=0&offset=-1\"" 2>/dev/null || true)"
    if [[ -n "${init_resp}" ]]; then
        local last_id
        last_id="$(printf '%s' "${init_resp}" | jq -r '.result[-1].update_id // empty' 2>/dev/null || true)"
        if [[ -n "${last_id}" && "${last_id}" =~ ^[0-9]+$ ]]; then
            offset=$(( last_id + 1 ))
        fi
    fi

    while true; do
        token="$(get_env_val "TELEGRAM_BOT_TOKEN" "${token}" "${env_file}")"
        allowed_chat="$(get_env_val "TELEGRAM_CHAT_ID" "${allowed_chat}" "${env_file}")"

        # Check for real-time alert transitions
        check_and_notify_alert_transitions "${token}" "${allowed_chat}" || true

        local updates
        updates="$(curl -fsSL --max-time 25 -K - <<<"url = \"https://api.telegram.org/bot${token}/getUpdates?timeout=15&offset=${offset}&allowed_updates=%5B%22message%22,%22callback_query%22%5D\"" 2>/dev/null || true)"

        if [[ -z "${updates}" || "${updates}" != *'"ok":true'* ]]; then
            sleep 5
            continue
        fi

        local count
        count="$(printf '%s' "${updates}" | jq -r '.result | length' 2>/dev/null || printf '0')"
        if (( count == 0 )); then
            continue
        fi

        local i
        for (( i = 0; i < count; i++ )); do
            local upd_id msg_chat_id msg_text cb_id cb_chat_id cb_msg_id cb_data
            upd_id="$(printf '%s' "${updates}" | jq -r ".result[${i}].update_id" 2>/dev/null || true)"
            if [[ -n "${upd_id}" && "${upd_id}" =~ ^[0-9]+$ ]]; then
                offset=$(( upd_id + 1 ))
            fi

            msg_chat_id="$(printf '%s' "${updates}" | jq -r ".result[${i}].message.chat.id // empty" 2>/dev/null || true)"
            msg_text="$(printf '%s' "${updates}" | jq -r ".result[${i}].message.text // empty" 2>/dev/null || true)"

            cb_id="$(printf '%s' "${updates}" | jq -r ".result[${i}].callback_query.id // empty" 2>/dev/null || true)"
            cb_chat_id="$(printf '%s' "${updates}" | jq -r ".result[${i}].callback_query.message.chat.id // empty" 2>/dev/null || true)"
            cb_msg_id="$(printf '%s' "${updates}" | jq -r ".result[${i}].callback_query.message.message_id // empty" 2>/dev/null || true)"
            cb_data="$(printf '%s' "${updates}" | jq -r ".result[${i}].callback_query.data // empty" 2>/dev/null || true)"

            if [[ -n "${msg_chat_id}" && -n "${msg_text}" ]]; then
                if [[ "${msg_chat_id}" != "${allowed_chat}" ]]; then
                    log_event "WARN" "Ignored unauthorized Telegram command from chat_id=${msg_chat_id}"
                    continue
                fi
                local reply_html
                reply_html="$(dispatch_bot_command "${msg_text}")"
                send_bot_reply "${token}" "${allowed_chat}" "${reply_html}"
            fi

            if [[ -n "${cb_id}" && -n "${cb_chat_id}" && -n "${cb_data}" ]]; then
                if [[ "${cb_chat_id}" != "${allowed_chat}" ]]; then
                    continue
                fi
                curl -fsSL --max-time 5 -X POST \
                    "https://api.telegram.org/bot${token}/answerCallbackQuery" \
                    -d "callback_query_id=${cb_id}" >/dev/null 2>&1 || true

                local edited_html
                edited_html="$(dispatch_bot_command "${cb_data}")"
                send_bot_reply "${token}" "${allowed_chat}" "${edited_html}" "${cb_msg_id}"
            fi
        done
    done
}

# --- Send Clean Status Card or Daily Report Immediately ---
send_interactive_status_card() {
    local mode="${1:-status}"
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local token chat_id
    token="$(get_env_val "TELEGRAM_BOT_TOKEN" "" "${env_file}")"
    chat_id="$(get_env_val "TELEGRAM_CHAT_ID" "" "${env_file}")"

    if [[ -z "${token}" || -z "${chat_id}" ]]; then
        msg_error "Telegram Bot Token or Chat ID is missing in ${env_file}."
        return 1
    fi

    register_bot_commands || true
    local html
    if [[ "${mode}" == "report" ]]; then
        html="$(format_msg_daily_report)"
    else
        html="$(format_msg_status)"
    fi
    send_bot_reply "${token}" "${chat_id}" "${html}"
    msg_ok "Sent live ${mode} card to Telegram (Sri Lanka Time)!"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-daemon}" in
        register|--register)
            register_bot_commands
            ;;
        send|--send|card)
            send_interactive_status_card "status"
            ;;
        report|--report|daily-report)
            send_interactive_status_card "report"
            ;;
        daemon|--daemon|*)
            run_bot_daemon
            ;;
    esac
fi
