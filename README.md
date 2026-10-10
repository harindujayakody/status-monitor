<div align="center">

# Infiax Status Monitor

**Production-Grade, Low-Memory Self-Hosted VPS & Uptime Monitoring Stack**

[![Validate Stack](https://github.com/harindujayakody/status-monitor/actions/workflows/validate.yml/badge.svg)](https://github.com/harindujayakody/status-monitor/actions/workflows/validate.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-0a66c2.svg)](LICENSE)
[![Ubuntu 22.04 | 24.04 LTS](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04%20LTS-E95420.svg)](https://ubuntu.com/server)
[![Arch: AMD64 | ARM64](https://img.shields.io/badge/Arch-AMD64%20%7C%20ARM64-0a66c2.svg)](compose.yaml)
[![RAM Footprint: ~215 MiB](https://img.shields.io/badge/RAM%20Footprint-~215%20MiB-2ea44f.svg)](compose.yaml)

<p align="center">
  <a href="#-architecture--security-model">Architecture</a> •
  <a href="#-stack-components--resource-budget">Components</a> •
  <a href="#-quick-start">Quick Start</a> •
  <a href="#-terminal-management-ui-infiax-monitor">Terminal UI</a> •
  <a href="#-post-install-configuration">Post-Install Setup</a> •
  <a href="#-documentation">Docs</a>
</p>

</div>

---

**Infiax Status Monitor** is a turnkey, security-hardened monitoring platform engineered for **Ubuntu Server 22.04 / 24.04 LTS** across both `amd64` and `arm64` architectures—specifically tuned to run effortlessly on **1 GiB RAM micro instances** (such as Oracle Cloud `VM.Standard.E2.1.Micro`).

It unifies **Uptime Kuma** (website, API, port, and SSL monitoring), **Beszel Hub & Agent** (lightweight server metrics, Docker container telemetry, and network latency tracking), and **Caddy** (automatic Let's Encrypt HTTPS/HTTP3 reverse proxy) behind an interactive terminal management suite (`infiax-monitor`).

---

## ✨ Why Infiax Status Monitor?

- ** Featherweight Memory Footprint (~215 MiB Total RAM)** — Replaces heavyweight Prometheus/Grafana/Chromium stacks with Go binaries and slim Node.js containers capped with explicit V8 heap and cgroup limits.
- **🔒 Zero-Trust Private Networking** — Only Caddy binds to public ports (`80/tcp`, `443/tcp`, `443/udp`). Uptime Kuma (`:3001`) and Beszel Hub (`:8090`) remain isolated on an internal Docker bridge, and Beszel Agent communicates with Beszel Hub over a **shared Unix domain socket** (`/beszel_socket/beszel.sock`) with zero public agent ports.
- **🛡️ Cloud Firewall & Oracle Cloud Safe** — Never flushes `iptables`, never touches Oracle Cloud's `InstanceServices` chain, never enables `ufw`, and never persists transient Docker chains into `/etc/iptables/rules.v4`.
- **🚫 Search-Engine & Crawler Blocked by Default** — Automatically serves `X-Robots-Tag: noindex, nofollow, noarchive, nosnippet, noimageindex, notranslate` headers and a strict `/robots.txt` (`Disallow: /`) across all monitoring endpoints.
- **🖥️ Interactive Terminal Control Center (`infiax-monitor`)** — 18 guided operations for installation, domain switching, Beszel key pairing, Telegram bot alerting, online SQLite backups, health checks, and safe uninstallation.
- **💾 Verified Online SQLite Backups** — Uses `sqlite3 .backup` for hot database snapshots, verifies `PRAGMA integrity_check`, generates SHA-256 manifests, and creates automatic pre-restore/pre-update rollback archives.

---

## 📦 Stack Components & Resource Budget

Measured on an Ubuntu 22.04 LTS micro VPS (~956 MiB physical RAM + 4 GiB swap):

| Container | Image (Pinned) | Network Exposure | Typical RAM | Hard Limit | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| `infiax-caddy` | `caddy:2.11.7-alpine` | Public `80`, `443/tcp+udp` | ~30 MiB | `128 MiB` | Reverse proxy, Let's Encrypt TLS, HTTP/3, crawler blocking |
| `infiax-uptime-kuma` | `louislam/uptime-kuma:2.5.6-slim` | Internal bridge `:3001` | ~150 MiB | `384 MiB` | HTTP(S), keyword, TCP port, DNS, and SSL expiry monitoring |
| `infiax-beszel-hub` | `henrygd/beszel:0.21.0` | Internal bridge `:8090` | ~27 MiB | `192 MiB` | Server metrics dashboard, historical charts, threshold alerts |
| `infiax-beszel-agent` | `henrygd/beszel-agent:0.21.0` | Unix socket (`beszel.sock`) | ~6 MiB | `128 MiB` | Host CPU, RAM, swap, disk I/O, network & container telemetry |

---

## 🏗️ Architecture & Security Model

```text
                             Internet (HTTPS 443 / HTTP 80)
                                           │
                                           ▼
                      ┌─────────────────────────────────────────┐
                      │           Caddy Reverse Proxy           │
                      │  • Automatic Let's Encrypt TLS & HTTP/3 │
                      │  • HSTS + X-Robots-Tag (No-Index)       │
                      │  • Built-in /robots.txt (Disallow: /)   │
                      └───────────┬─────────────────┬───────────┘
                                  │                 │
           https://status.example.com             https://monitor.example.com
            (Internal Bridge :3001)                 (Internal Bridge :8090)
                                  │                 │
                                  ▼                 ▼
                      ┌───────────────────┐ ┌───────────────────┐
                      │    Uptime Kuma    │ │    Beszel Hub     │
                      │  (Status & HTTP)  │ │ (Metrics & Alerts)│
                      └─────────┬─────────┘ └─────────┬─────────┘
                                │                     │
                                │             Shared Unix Socket
                                │          (/beszel_socket/beszel.sock)
                                │                     │
                                │                     ▼
                                │           ┌───────────────────┐
                                │           │   Beszel Agent    │
                                │           │ (Host & Container │
                                │           │     Telemetry)    │
                                │           └───────────────────┘
                                │                     │
                                └──────────┬──────────┘
                                           │ Outbound HTTPS (443)
                                           ▼
                                ┌───────────────────────┐
                                │   Telegram Bot API    │
                                │  (Instant Alerting)   │
                                └───────────────────────┘
```

---

## 🚀 Quick Start

### 1. Prepare DNS Records

Create two **DNS `A` records** pointing to your server's public IPv4 address:

| Hostname (Example) | Record | Target IPv4 | Routed Service |
| :--- | :--- | :--- | :--- |
| `status.example.com` | `A` | `203.0.113.10` | **Uptime Kuma** (Status Page & Monitors) |
| `monitor.example.com` | `A` | `203.0.113.10` | **Beszel Hub** (Server & Container Metrics) |

> [!IMPORTANT]
> - **Use hyphens (`dev-monitor`), never underscores (`dev_monitor`)** — underscores are invalid in hostnames and rejected by Let's Encrypt.
> - **Remove conflicting IPv6 `AAAA` records** unless IPv6 is actively routed on your VPS.
> - **Cloudflare Users**: Set both records to **DNS Only (Grey Cloud)** during initial installation so Caddy can complete Let's Encrypt HTTP-01 validation, or set Cloudflare **SSL/TLS encryption mode** to **Full (strict)** once certificates are issued.

### 2. Run the One-Click Installer

Clone the repository onto your Ubuntu server and run `install.sh`:

```bash
git clone https://github.com/harindujayakody/status-monitor.git
cd status-monitor

# Optional: Run read-only preflight & compatibility checks without making changes
sudo bash install.sh --dry-run

# Interactive production installation (deploys to /opt/infiax-status-monitor)
sudo bash install.sh
```

Or deploy non-interactively with custom flags:

```bash
sudo bash install.sh --yes \
  --status-domain status.example.com \
  --beszel-domain monitor.example.com \
  --acme-email admin@example.com
```

---

## 🖥️ Terminal Management UI (`infiax-monitor`)

After installation, launch the interactive control panel from any directory:

```bash
sudo infiax-monitor
```

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

### Non-Interactive CLI Subcommands

Every menu operation can also be executed directly for scripts or cron jobs:

```bash
sudo infiax-monitor info                  # System, CPU, RAM, swap & disk summary
sudo infiax-monitor preflight             # DNS, port, resource & firewall audit
sudo infiax-monitor status                # Container health & real-time memory usage
sudo infiax-monitor logs                  # Tail logs across all containers
sudo infiax-monitor logs caddy 100        # Tail last 100 lines of a specific service
sudo infiax-monitor domains               # Update domains & reload Caddy TLS
sudo infiax-monitor beszel-agent          # View or update Beszel Agent key/token
sudo infiax-monitor telegram              # Guided Telegram Bot & Chat ID setup
sudo infiax-monitor test-telegram         # Send a live test alert to Telegram
sudo infiax-monitor backup                # Create verified online SQLite backup
sudo infiax-monitor backup --list         # List available backup archives & checksums
sudo infiax-monitor restore               # Restore from a verified backup archive
sudo infiax-monitor update                # Pre-backup, pull images & recreate stack
sudo infiax-monitor health                # Deep container, socket, DB & HTTPS check
sudo infiax-monitor troubleshoot          # Automated root-cause diagnostics
sudo infiax-monitor uninstall --dry-run   # Preview uninstallation without changes
```

---

## 🔧 Post-Install Configuration

### 1. Pair Beszel Agent (Local Unix Socket)

During installation, `install.sh` automatically extracts the Beszel Hub ED25519 public key and configures `infiax-beszel-agent`. To complete pairing in the web UI:

1. Open `https://monitor.example.com` and create your administrator account.
2. Click **+ Add System** and select the **Docker** tab.
3. Set **Name** to your server name and **Host / IP** to:
   ```text
   /beszel_socket/beszel.sock
   ```
4. Click **Add system**. Within seconds, your server status will turn **Green (Up)** with live CPU, memory, disk, network, and container metrics.

### 2. Optional: Add Beszel Network Latency Monitors

In Beszel (`https://monitor.example.com` -> **Network Monitors** -> **+ Add Monitor**), you can track outbound network latency and packet loss from your VPS agent:

| Type | Name | Target | Interval | Purpose |
| :--- | :--- | :--- | :--- | :--- |
| `Ping` | `Cloudflare Edge` | `1.1.1.1` | `60s` | Measures baseline VPS datacenter network latency & packet loss |
| `TCP` / `HTTP` | `Production Site` | `example.com:443` | `60s` | Measures reachability from your VPS to your production services |

### 3. Configure Telegram Instant Alerts & Interactive Bot Commands

1. Run `sudo infiax-monitor telegram` (Option **12**) to configure your `@BotFather` token and auto-detect your Chat ID (stored in `/opt/infiax-status-monitor/.env` with `0600` permissions).
2. Run `sudo infiax-monitor test-telegram` (Option **13**) to register premade Telegram slash commands (`setMyCommands`), start the lightweight `infiax-telegram-bot` responder service, and send an interactive live dashboard card with inline buttons to your Telegram chat:
   - `/status` — 📊 Full Server, Uptime, Network & Container Summary
   - `/metrics` — ⚡ Live CPU, RAM, Swap & Disk Usage with visual bars (`▰▰▰▱▱▱▱▱▱▱`)
   - `/containers` — 🐳 Docker Container Health & Memory Usage
   - `/network` — 🌐 Outbound Ping Latency (`1.1.1.1`) & HTTPS Endpoint Status
   - `/alerts` — 🔔 Audit All 6 Beszel Alert Thresholds
   - `/help` — 🤖 Show Interactive Command Menu & Inline Buttons
3. Enable push notifications in:
   - **Uptime Kuma** (`Settings -> Notifications -> Telegram`)
   - **Beszel Hub** (`Settings -> Notifications` using `telegram://<BOT_TOKEN>@telegram?chats=<CHAT_ID>`)

---

## 💾 Backup, Restore & Safe Uninstallation

- **Verified Hot Backups (`sudo infiax-monitor backup`)**
  Performs online SQLite `.backup` snapshots of Uptime Kuma and Beszel databases without stopping monitoring, validates `PRAGMA integrity_check`, packs `.env`, `compose.yaml`, and `Caddyfile` into `/opt/infiax-status-monitor/backups/`, and writes a `.sha256` checksum manifest.
- **Safe Uninstaller (`sudo ./uninstall.sh`)**
  - **Mode 1 — Preserve Data**: Stops and removes containers and networks while keeping `/opt/infiax-status-monitor/data` and `backups` intact.
  - **Mode 2 — Complete Removal**: Creates an optional final backup, verifies path safety, and cleanly removes the stack without touching Docker Engine or host firewall rules.

---

## 📚 Documentation

| Guide | Description |
| :--- | :--- |
| [Installation Guide](docs/installation.md) | System requirements, DNS setup, dry-run checks, and installer flags |
| [Configuration Reference](docs/configuration.md) | Directory layout, `.env` variables, memory tuning, and domain switching |
| [Telegram Alerting Guide](docs/telegram.md) | `@BotFather` setup, Chat ID discovery, Uptime Kuma & Beszel Shoutrrr URLs |
| [Security & Firewall Guide](docs/security.md) | Zero-trust networking, Unix socket isolation, and Oracle Cloud `iptables` rules |
| [Backup & Restore Guide](docs/backup-restore.md) | Online SQLite backup architecture, retention policy, and disaster recovery |
| [Uninstallation Guide](docs/uninstall.md) | Mode 1 (Preserve Data), Mode 2 (Full Purge), and `--dry-run` previews |
| [Troubleshooting Guide](docs/troubleshooting.md) | Fixes for Let's Encrypt TLS, Beszel socket pairing, and `502 Bad Gateway` |

---

## 📄 License

Released under the [MIT License](LICENSE).
