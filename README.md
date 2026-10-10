<div align="center">

# Infiax Status Monitor

**Self-Hosted Server & Website Monitoring — Runs on a 1 GiB VPS**

[![Validate Stack](https://github.com/harindujayakody/status-monitor/actions/workflows/validate.yml/badge.svg)](https://github.com/harindujayakody/status-monitor/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-0a66c2.svg)](LICENSE)
[![Ubuntu 22.04 | 24.04 LTS](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20LTS-E95420.svg)](https://ubuntu.com/server)
[![Arch: AMD64 | ARM64](https://img.shields.io/badge/Arch-AMD64%20%7C%20ARM64-0a66c2.svg)](compose.yaml)
[![RAM Footprint: ~215 MiB](https://img.shields.io/badge/RAM%20Footprint-~215%20MiB-2ea44f.svg)](compose.yaml)

</div>

---

**Infiax Status Monitor** is a self-hosted monitoring setup for your VPS. It watches your websites, tracks server health (CPU, RAM, disk), and sends you Telegram alerts when something goes wrong.

It's built to run on small servers — even a free Oracle Cloud micro instance with just 1 GiB of RAM works fine.

---

## What's included

- **Uptime Kuma** — checks if your websites are up, monitors SSL expiry, ports, and response time
- **Beszel Hub + Agent** — shows live server stats like CPU, RAM, disk usage, and Docker container health
- **Caddy** — handles HTTPS automatically using Let's Encrypt; the only service that's exposed to the internet
- **Telegram Bot** — sends alerts and lets you check your server status by typing commands in Telegram

---

## How the network is set up

```text
                         Internet (HTTPS 443 / HTTP 80)
                                       │
                                       ▼
                    ┌─────────────────────────────────┐
                    │         Caddy Reverse Proxy      │
                    │  • Auto HTTPS via Let's Encrypt  │
                    │  • Blocks search engine crawlers │
                    └────────────┬──────────┬──────────┘
                                 │          │
             https://status.example.com   https://monitor.example.com
                  (internal :3001)              (internal :8090)
                                 │          │
                                 ▼          ▼
                    ┌──────────────┐  ┌──────────────┐
                    │  Uptime Kuma │  │  Beszel Hub  │
                    └──────────────┘  └──────┬───────┘
                                             │
                                       Unix Socket
                                   (beszel_socket.sock)
                                             │
                                             ▼
                                    ┌─────────────────┐
                                    │  Beszel Agent   │
                                    │ (Host & Docker) │
                                    └────────┬────────┘
                                             │
                                    ┌────────▼────────┐
                                    │  Telegram Bot   │
                                    └─────────────────┘
```

Only Caddy is open to the internet. Everything else talks internally — Beszel Agent connects to Beszel Hub through a Unix socket, so no extra ports are needed.

---

## Resource usage

Measured on Ubuntu 22.04 LTS with ~956 MiB RAM + 4 GiB swap:

| Container | Image | Typical RAM | Max Limit | What it does |
| :--- | :--- | :--- | :--- | :--- |
| `infiax-caddy` | `caddy:2.11.7-alpine` | ~30 MiB | 128 MiB | HTTPS proxy, TLS, crawler blocking |
| `infiax-uptime-kuma` | `louislam/uptime-kuma:2.5.6-slim` | ~150 MiB | 384 MiB | Website & port monitoring |
| `infiax-beszel-hub` | `henrygd/beszel:0.21.0` | ~27 MiB | 192 MiB | Server metrics dashboard |
| `infiax-beszel-agent` | `henrygd/beszel-agent:0.21.0` | ~6 MiB | 128 MiB | Collects CPU, RAM, disk, container stats |

Total: around **215 MiB** on a quiet server.

---

## Before you install

You need:
- An Ubuntu 22.04 or 24.04 LTS server (amd64 or arm64)
- At least 1 GiB RAM (512 MiB works too if you have swap)
- Two domain names (or subdomains) pointing to your server's IP
- Docker and Docker Compose installed (the installer checks this for you)
- A Telegram bot token from [@BotFather](https://t.me/BotFather) if you want alerts

---

## Quick Start

### 1. Set up DNS

Create two DNS `A` records pointing to your server's public IP:

| Subdomain | Record | Target | Goes to |
| :--- | :--- | :--- | :--- |
| `status.example.com` | `A` | `203.0.113.10` | Uptime Kuma |
| `monitor.example.com` | `A` | `203.0.113.10` | Beszel Hub |

> [!IMPORTANT]
> Use hyphens in subdomain names, not underscores — Let's Encrypt rejects underscores.
> If you use Cloudflare, set both records to **DNS Only (grey cloud)** so Let's Encrypt can verify your domain.

### 2. Run the installer

Clone the repo on your server and run the installer:

```bash
git clone https://github.com/harindujayakody/status-monitor.git
cd status-monitor

# Check if your server is ready (no changes made)
sudo bash install.sh --dry-run

# Install everything
sudo bash install.sh
```

Or run it without prompts:

```bash
sudo bash install.sh --yes \
  --status-domain status.example.com \
  --beszel-domain monitor.example.com \
  --acme-email admin@example.com
```

---

## Management menu

After installing, run this from anywhere:

```bash
sudo infiax-monitor
```

You'll see a menu like this:

```text
  I N F I A X
  STATUS MONITOR (v1.0.0)
  ────────────────────────────────────
  Status: https://status.example.com   Beszel: https://monitor.example.com
  Host:   ubuntu-server (amd64)        RAM: 284/956 MiB
  ────────────────────────────────────

  SERVER                              NOTIFICATIONS
    01. System Information              12. Telegram Setup Guide
    02. Preflight Checks                13. Test Notifications

  INSTALLATION                        MAINTENANCE
    03. Install Monitoring Stack        14. Backup Data
    04. Configure Domains               15. Restore Backup
    05. Configure Beszel Agent          16. Health Checks
                                        17. Troubleshooting
  SERVICES
    06. Start Services                REMOVAL
    07. Stop Services                   18. Uninstall Monitoring Stack
    08. Restart Services
    09. Update Services                 00. Exit
    10. Service Status
    11. View Logs
  ────────────────────────────────────
  Select option [00-18]:
```

You can also run things directly from the command line:

```bash
sudo infiax-monitor info           # System info summary
sudo infiax-monitor status         # Container health & RAM usage
sudo infiax-monitor logs           # Live logs from all containers
sudo infiax-monitor backup         # Create a database backup
sudo infiax-monitor restore        # Restore from a backup
sudo infiax-monitor telegram       # Set up Telegram alerts
sudo infiax-monitor health         # Deep health check
sudo infiax-monitor uninstall      # Remove everything
```

---

## After installing

### Connect Beszel Agent

1. Open `https://monitor.example.com` and create your admin account.
2. Click **+ Add System** → select the **Docker** tab.
3. Set the host to: `/beszel_socket/beszel.sock`
4. Click **Add system** — it should go green within a few seconds.

### Set up Telegram alerts

1. Run `sudo infiax-monitor telegram` (Option **12**) — it walks you through pasting your bot token and finding your Chat ID.
2. Run `sudo infiax-monitor test-telegram` (Option **13**) — this registers the bot commands and sends a test message to your Telegram.

Then enable notifications in:
- **Uptime Kuma** → `Settings → Notifications → Telegram`
- **Beszel Hub** → `Settings → Notifications` using `telegram://<BOT_TOKEN>@telegram?chats=<CHAT_ID>`

### Telegram bot commands

Once set up, you can type these commands in Telegram:

| Command | What it shows |
| :--- | :--- |
| `/status` | Server uptime, CPU, RAM, disk, and website status |
| `/metrics` | Live CPU, RAM, swap & disk with usage bars |
| `/containers` | Docker container health and memory |
| `/network` | Ping latency to Cloudflare DNS & your site status |
| `/alerts` | All active Beszel alert thresholds |
| `/report` | Full daily summary (also sent every night at 9 PM) |

The bot also sends you automatic alerts when something goes down, and a full report every night at 9:00 PM (Sri Lanka time).

---

## Backups

Run `sudo infiax-monitor backup` to back up your data while everything keeps running.

It saves a snapshot of the Uptime Kuma and Beszel databases, plus your config files (`.env`, `compose.yaml`, `Caddyfile`). Each backup also gets a checksum file so you can verify it wasn't corrupted.

Backups are stored in `/opt/infiax-status-monitor/backups/`.

---

## Uninstalling

Run `sudo ./uninstall.sh` — it will ask you which mode you want:

- **Mode 1 – Keep data**: Removes containers but keeps your database and backup files.
- **Mode 2 – Full removal**: Removes everything. It can take an optional final backup before deleting.

Neither mode touches Docker itself or your firewall rules.

---

## Documentation

| Guide | What's in it |
| :--- | :--- |
| [Installation Guide](docs/installation.md) | Requirements, DNS setup, dry-run, installer flags |
| [Configuration Reference](docs/configuration.md) | Folder layout, `.env` settings, domain changes |
| [Telegram Alerting Guide](docs/telegram.md) | BotFather setup, Chat ID, Uptime Kuma & Beszel URLs |
| [Security & Firewall Guide](docs/security.md) | How networking works, Unix socket isolation |
| [Backup & Restore Guide](docs/backup-restore.md) | How backups work, restore steps |
| [Uninstallation Guide](docs/uninstall.md) | Mode 1, Mode 2, and dry-run preview |
| [Troubleshooting Guide](docs/troubleshooting.md) | TLS errors, Beszel socket issues, 502 errors |

---

## License

Released under the [MIT License](LICENSE).
