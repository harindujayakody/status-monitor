# Telegram Notification Setup Guide

**Infiax Status Monitor** uses native Telegram integrations in both **Uptime Kuma** and **Beszel Hub**, complemented by an interactive CLI setup and test utility.

---

## 1. Create a Telegram Bot via `@BotFather`

1. Open Telegram and start a conversation with [`@BotFather`](https://t.me/BotFather).
2. Send the command `/newbot`.
3. Provide a display name (e.g., `Infiax Status Monitor`) and a unique username ending in `bot` (e.g., `infiax_status_bot`).
4. Copy the **HTTP API Bot Token** (example format: `1234567890:AAH_exampleTokenStringHere`).
5. Click the link to your new bot in Telegram and press **Start** (or send `/start`) so the bot is permitted to message you.

---

## 2. Obtain Your Chat ID & Test Delivery

Launch the guided Telegram setup utility (requires `sudo` to save credentials to `/opt/infiax-status-monitor/.env`):

```bash
sudo /opt/infiax-status-monitor/monitor.sh telegram
```

Or choose **12. Telegram Setup Guide** from `sudo ./monitor.sh`:

1. Enter your **Bot Token** (input is hidden and never written to log files).
2. The script automatically queries `getUpdates` to detect your **Chat ID** if you recently messaged your bot, or lets you enter your numeric Chat ID manually.
3. Credentials are stored in `/opt/infiax-status-monitor/.env` with `0600` permissions.
4. Select **Yes** when prompted to send a live test notification (or run `sudo ./monitor.sh test-telegram` / Menu Option **13** at any time).

---

## 3. Configure Uptime Kuma Notifications

1. Log in to Uptime Kuma at `https://status.example.com`.
2. Navigate to **Settings** (top-right menu) -> **Notifications** -> **Setup Notification**.
3. Configure the following fields:
   - **Notification Type**: `Telegram`
   - **Friendly Name**: `Infiax Telegram Alerts`
   - **Bot Token**: Paste your BotFather token
   - **Chat ID**: Paste your Chat ID (or click *Auto Get* after messaging the bot)
   - **Default enabled**: Turn **ON**
   - **Apply on all existing monitors**: Turn **ON**
4. Click **Test** to verify delivery, then click **Save**.
5. Uptime Kuma will now automatically send notifications whenever any monitored website/API goes **DOWN** and when it recovers (**UP**).

---

## 4. Configure Beszel Hub Resource Alerts

Beszel Hub uses Shoutrrr notification URLs for resource threshold and recovery alerts.

1. Log in to Beszel Hub at `https://monitor.example.com`.
2. Navigate to **Settings** (gear icon) -> **Notifications**.
3. Under **Webhook / Notification URLs**, add your Telegram Shoutrrr URL (generated for you by Menu Option 12):
   ```text
   telegram://<YOUR_BOT_TOKEN>@telegram?chats=<YOUR_CHAT_ID>
   ```
4. Click **Test Notification** and **Save Settings**.
5. Return to the main Beszel dashboard and click the **Bell Icon (Alerts)** on your VPS system row to configure thresholds:
   - **System Status**: Alert when system disconnects / recovers
   - **CPU Usage**: e.g., `> 85%` for `5 minutes`
   - **Memory Usage**: e.g., `> 85%` for `5 minutes`
   - **Disk Usage**: e.g., `> 80%`

---

## 5. Architectural Note on Complete VPS Outages

Because Uptime Kuma and Beszel Hub run **on** your VPS, a total power failure, hypervisor outage, or complete upstream network loss on that VPS will prevent the server from sending outbound Telegram messages about its own outage.

**Best Practice**: Register `https://status.example.com` on a free external ping monitor or secondary node so you are alerted even if your VPS becomes completely unreachable from the internet.
