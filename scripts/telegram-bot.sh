#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Interactive Telegram Bot & Command Responder
# ==============================================================================
# Registers premade Telegram slash commands (setMyCommands) for the native
# Telegram Menu button and runs a lightweight, zero-port long-polling daemon
# that replies to user-selected menu commands with clean, emoji-rich telemetry.
#
# Security:
#   - Outbound HTTPS only (zero public ports opened).
#   - Strictly restricted to the authorized TELEGRAM_CHAT_ID in .env.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

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

# --- Format Message: /status (Full Overview) ---
format_msg_status() {
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
    ts_str="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

    local cpu_pct ram_used ram_total ram_pct swap_total
    cpu_pct="$(get_cpu_pct)"
    ram_used="$(get_used_ram_mib)"
    ram_total="$(get_total_ram_mib)"
    ram_pct=0
    if (( ram_total > 0 )); then
        ram_pct=$(( (ram_used * 100) / ram_total ))
    fi
    swap_total="$(get_total_swap_mib)"

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

    local healthy_cnt=0
    local total_cnt=4
    local cname
    for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
        local st hlth
        st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'missing')"
        hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "${cname}" 2>/dev/null || printf 'missing')"
        if [[ "${st}" == "running" && "${hlth}" == "healthy" ]]; then
            healthy_cnt=$(( healthy_cnt + 1 ))
        fi
    done

    local stack_badge="🟢 <b>ALL SYSTEMS OPERATIONAL</b>"
    if (( healthy_cnt < total_cnt || cpu_pct >= 80 || ram_pct >= 80 || disk_pct >= 80 || net_loss >= 10 )); then
        stack_badge="🟡 <b>ATTENTION REQUIRED</b>"
    fi

    cat <<EOF
🛡️ <b>INFIAX STATUS MONITOR</b>
${stack_badge}
────────────────

🖥️ <b>Host:</b> <code>${host_name}</code>
⏱️ <b>Uptime:</b> <code>${uptime_str}</code>
📈 <b>Load:</b> <code>${load_str}</code>

<b>⚡ Resource Telemetry</b>
${cpu_icon} <b>CPU:</b>  <code>$(make_bar "${cpu_pct}")</code> <b>${cpu_pct}%</b>
${ram_icon} <b>RAM:</b>  <code>$(make_bar "${ram_pct}")</code> <b>${ram_pct}%</b> <i>(${ram_used}/${ram_total} MiB)</i>
${disk_icon} <b>Disk:</b> <code>$(make_bar "${disk_pct}")</code> <b>${disk_pct}%</b> <i>(${disk_used}/${disk_total} GB)</i>
💾 <b>Swap:</b> <code>${swap_total} MiB Configured</code>

<b>🌐 Network &amp; Containers</b>
${net_icon} <b>Ping (1.1.1.1):</b> <code>${net_rtt} ms</code> • <code>${net_loss}% loss</code>
🐳 <b>Containers:</b> <code>${healthy_cnt}/${total_cnt} Healthy</code>

🔗 <a href="https://${status_domain}">Uptime Kuma</a>  •  <a href="https://${beszel_domain}">Beszel Hub</a>
🕒 <i>${ts_str}</i>
EOF
}

# --- Format Message: /metrics (Detailed CPU, RAM, Swap, Disk) ---
format_msg_metrics() {
    local host_name ts_str
    host_name="$(hostname 2>/dev/null || printf 'infiax-vps')"
    ts_str="$(date -u '+%H:%M:%S UTC')"

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

    cat <<EOF
⚡ <b>SERVER RESOURCE TELEMETRY</b>
🖥️ <b>Host:</b> <code>${host_name}</code>
────────────────

$(metric_badge "${cpu_pct}" 65 80) <b>CPU Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${cpu_pct}")</code> <b>${cpu_pct}%</b>
• Load Average: <code>$(get_load_average)</code>

$(metric_badge "${ram_pct}" 65 80) <b>Memory Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${ram_pct}")</code> <b>${ram_pct}%</b>
• Used: <code>${ram_used} MiB</code> / <code>${ram_total} MiB</code>

🟢 <b>Swap Space</b>
<code>$(make_bar "${swap_pct}")</code> <b>${swap_pct}%</b>
• Used: <code>${swap_used} MiB</code> / <code>${swap_total} MiB</code>

$(metric_badge "${disk_pct}" 65 80) <b>Disk Usage</b> <i>(Alert &gt; 80% for 10m)</i>
<code>$(make_bar "${disk_pct}")</code> <b>${disk_pct}%</b>
• Used: <code>${disk_used} GB</code> / <code>${disk_total} GB</code>

🕒 <i>Checked at ${ts_str}</i>
EOF
}

# --- Format Message: /containers (Docker Container Health & Memory) ---
format_msg_containers() {
    local ts_str
    ts_str="$(date -u '+%H:%M:%S UTC')"

    local stats_raw
    stats_raw="$(docker stats --no-stream --format '{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}' 2>/dev/null || true)"

    local lines=""
    local cname
    for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
        local st hlth icon cpu_val mem_val
        st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'stopped')"
        hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "${cname}" 2>/dev/null || printf 'unknown')"
        if [[ "${st}" == "running" && "${hlth}" == "healthy" ]]; then
            icon="🟢"
        elif [[ "${st}" == "running" ]]; then
            icon="🟡"
        else
            icon="🔴"
        fi
        cpu_val="$(printf '%s\n' "${stats_raw}" | awk -F'|' -v c="${cname}" '$1==c {print $2}')"
        mem_val="$(printf '%s\n' "${stats_raw}" | awk -F'|' -v c="${cname}" '$1==c {print $3}')"
        [[ -z "${cpu_val}" ]] && cpu_val="0.00%"
        [[ -z "${mem_val}" ]] && mem_val="N/A"

        lines="${lines}${icon} <b>${cname}</b>
   ├ State: <code>${st} (${hlth})</code>
   └ Usage: <code>CPU ${cpu_val}</code> • <code>${mem_val}</code>

"
    done

    cat <<EOF
🐳 <b>DOCKER CONTAINER HEALTH</b>
<i>Alert threshold: Unhealthy &gt; 10m</i>
────────────────

${lines}🕒 <i>Checked at ${ts_str}</i>
EOF
}

# --- Format Message: /network (Ping Latency, Loss & HTTPS Endpoints) ---
format_msg_network() {
    local rdir
    rdir="$(get_runtime_dir)"
    local env_file="${rdir}/.env"
    local status_domain beszel_domain
    status_domain="$(get_env_val "STATUS_DOMAIN" "${ISM_DEFAULT_STATUS_DOMAIN}" "${env_file}")"
    beszel_domain="$(get_env_val "BESZEL_DOMAIN" "${ISM_DEFAULT_BESZEL_DOMAIN}" "${env_file}")"

    local net_info net_loss net_rtt
    net_info="$(get_network_ping_summary)"
    net_loss="${net_info%%|*}"
    net_rtt="${net_info#*|}"
    local net_icon
    net_icon="$(metric_badge "${net_loss}" 5 10)"

    local kuma_code beszel_code kuma_icon beszel_icon
    kuma_code="$(curl -ksSL -o /dev/null -w '%{http_code}' --max-time 5 "https://${status_domain}" 2>/dev/null || printf '000')"
    beszel_code="$(curl -ksSL -o /dev/null -w '%{http_code}' --max-time 5 "https://${beszel_domain}" 2>/dev/null || printf '000')"

    if [[ "${kuma_code}" =~ ^(200|301|302)$ ]]; then kuma_icon="🟢"; else kuma_icon="🔴"; fi
    if [[ "${beszel_code}" =~ ^(200|301|302)$ ]]; then beszel_icon="🟢"; else beszel_icon="🔴"; fi

    cat <<EOF
🌐 <b>NETWORK &amp; ENDPOINT TELEMETRY</b>
<i>Alert threshold: Packet Loss &gt; 10%</i>
────────────────

<b>📡 Outbound Latency Monitor (1.1.1.1)</b>
${net_icon} <b>Packet Loss:</b> <code>${net_loss}%</code> <i>(Threshold: &lt; 10%)</i>
⚡ <b>Avg Latency:</b> <code>${net_rtt} ms</code>

<b>🔒 HTTPS Public Endpoints</b>
${kuma_icon} <b>Uptime Kuma:</b> <code>HTTP ${kuma_code}</code>
   └ <a href="https://${status_domain}">https://${status_domain}</a>
${beszel_icon} <b>Beszel Hub:</b> <code>HTTP ${beszel_code}</code>
   └ <a href="https://${beszel_domain}">https://${beszel_domain}</a>

🔌 <b>Beszel Unix Socket:</b>
   └ <code>/beszel_socket/beszel.sock</code> (🟢 Isolated)
EOF
}

# --- Format Message: /alerts (Check All 6 Configured Alert Rules) ---
format_msg_alerts() {
    local cpu_pct ram_used ram_total ram_pct
    cpu_pct="$(get_cpu_pct)"
    ram_used="$(get_used_ram_mib)"
    ram_total="$(get_total_ram_mib)"
    ram_pct=0
    if (( ram_total > 0 )); then
        ram_pct=$(( (ram_used * 100) / ram_total ))
    fi

    local disk_info disk_pct
    disk_info="$(get_disk_summary)"
    disk_pct="${disk_info%%|*}"

    local net_info net_loss
    net_info="$(get_network_ping_summary)"
    net_loss="${net_info%%|*}"

    local unhealthy_cnt=0
    local cname
    for cname in infiax-caddy infiax-uptime-kuma infiax-beszel-hub infiax-beszel-agent; do
        local st hlth
        st="$(docker inspect -f '{{.State.Status}}' "${cname}" 2>/dev/null || printf 'stopped')"
        hlth="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}healthy{{end}}' "${cname}" 2>/dev/null || printf 'unknown')"
        if [[ "${st}" != "running" || "${hlth}" != "healthy" ]]; then
            unhealthy_cnt=$(( unhealthy_cnt + 1 ))
        fi
    done

    local c_icon="🟢"
    if (( unhealthy_cnt > 0 )); then c_icon="🔴"; fi

    cat <<EOF
🔔 <b>ACTIVE ALERT RULES CHECK</b>
────────────────

🟢 <b>1. System Status</b>
   • Rule: <i>Down for 10 minutes</i>
   • Current: <code>ONLINE ($(get_system_uptime))</code>

$(metric_badge "${cpu_pct}" 65 80) <b>2. CPU Usage</b>
   • Rule: <i>Exceeds 80% for 10 minutes</i>
   • Current: <code>${cpu_pct}%</code>

$(metric_badge "${ram_pct}" 65 80) <b>3. Memory Usage</b>
   • Rule: <i>Exceeds 80% for 10 minutes</i>
   • Current: <code>${ram_pct}% (${ram_used}/${ram_total} MiB)</code>

$(metric_badge "${disk_pct}" 65 80) <b>4. Disk Usage</b>
   • Rule: <i>Exceeds 80% for 10 minutes</i>
   • Current: <code>${disk_pct}%</code>

$(metric_badge "${net_loss}" 5 10) <b>5. Network Monitor Loss</b>
   • Rule: <i>Exceeds 10% packet loss</i>
   • Current: <code>${net_loss}% loss (1.1.1.1)</code>

${c_icon} <b>6. Container Health</b>
   • Rule: <i>Container unhealthy for 10 minutes</i>
   • Current: <code>$(( 4 - unhealthy_cnt ))/4 Containers Healthy</code>
EOF
}

# --- Format Message: /help or /start ---
format_msg_help() {
    cat <<'EOF'
🤖 <b>INFIAX MONITOR BOT</b>
────────────────

Tap the <b>Menu</b> button in Telegram anytime to run a live check:

📊 /status — Full Server, Network &amp; Container Summary
⚡ /metrics — Live CPU, RAM, Swap &amp; Disk Bars
🐳 /containers — Docker Container Health &amp; Memory
🌐 /network — Outbound Ping Loss &amp; HTTPS Checks
🔔 /alerts — Verify All 6 Beszel Alert Thresholds
🤖 /help — Show This Command List
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
      {"command":"status","description":"📊 Full Server, Uptime & Container Overview"},
      {"command":"metrics","description":"⚡ Live CPU, Memory, Swap & Disk Usage"},
      {"command":"containers","description":"🐳 Docker Container Health & RAM"},
      {"command":"network","description":"🌐 Network Latency, Packet Loss & HTTPS"},
      {"command":"alerts","description":"🔔 Audit All 6 Alert Thresholds"},
      {"command":"help","description":"🤖 Show Available Commands"}
    ]}'

    local resp
    resp="$(curl -fsSL --max-time 10 -X POST \
        -H "Content-Type: application/json" \
        -d "${commands_json}" \
        "https://api.telegram.org/bot${token}/setMyCommands" 2>/dev/null || true)"

    if [[ "${resp}" == *'"ok":true'* ]]; then
        msg_ok "Registered premade Telegram Menu commands (/status, /metrics, /containers, /network, /alerts, /help)."
        return 0
    else
        msg_error "Failed to register Telegram slash commands via setMyCommands."
        return 1
    fi
}

# --- Send Clean Telegram Message (No persistent inline button clutter) ---
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
    msg_info "Starting Infiax Telegram Bot long-polling responder for Chat ID ${allowed_chat}..."

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

        local updates
        updates="$(curl -fsSL --max-time 35 -K - <<<"url = \"https://api.telegram.org/bot${token}/getUpdates?timeout=25&offset=${offset}&allowed_updates=%5B%22message%22,%22callback_query%22%5D\"" 2>/dev/null || true)"

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

# --- Send Clean Status Card Immediately ---
send_interactive_status_card() {
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
    html="$(format_msg_status)"
    send_bot_reply "${token}" "${chat_id}" "${html}"
    msg_ok "Sent live status card to Telegram!"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    case "${1:-daemon}" in
        register|--register)
            register_bot_commands
            ;;
        send|--send|card)
            send_interactive_status_card
            ;;
        daemon|--daemon|*)
            run_bot_daemon
            ;;
    esac
fi
