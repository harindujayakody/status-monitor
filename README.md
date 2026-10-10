# Infiax Status Monitor

[![License: MIT](https://img.shields.io/badge/License-MIT-0a66c2.svg)](LICENSE)
[![Platform: Ubuntu 22.04 LTS](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420.svg)](https://ubuntu.com/server)
[![Arch: AMD64 | ARM64](https://img.shields.io/badge/Arch-AMD64%20%7C%20ARM64-0a66c2.svg)](compose.yaml)

**Infiax Status Monitor** is a production-ready, self-hosted VPS monitoring and management system engineered for Ubuntu Server 22.04 LTS (including low-memory Oracle Cloud `VM.Standard.E2.1.Micro` instances).

It combines **Uptime Kuma**, **Beszel Hub**, **Beszel Agent**, and **Caddy** behind a zero-trust internal network with an interactive terminal management interface (`monitor.sh`), verified SQLite backups, guided Telegram alerting, and strict preservation of native Oracle Cloud `iptables` firewall rules.

---

## Key Features

- **Unified Monitoring Stack**:
  - **Uptime Kuma (`v2.5.6-slim`)** at `https://status.infiax.com` — Website, HTTPS, API, port, and certificate monitoring with public status pages.
  - **Beszel Hub & Agent (`v0.21.0`)** at `https://dev-monitor.infiax.com` — Lightweight CPU, RAM, swap, disk, network bandwidth, and Docker container metrics.
  - **Caddy (`v2.11.7-alpine`)** — Automatic Let's Encrypt HTTPS, HTTP/3, WebSocket proxying, HSTS headers, and rotated access logs.
- **Tuned for Low-Memory Micro Servers (~956 MiB RAM)**:
  - Uses lightweight Go and slim Node.js images (no Prometheus, Grafana, Elasticsearch, or bundled Chromium bloat).
  - Enforces sensible container memory caps and Node.js V8 heap bounds (`--max-old-space-size=256`).
- **Private-by-Default Networking**:
  - Only Caddy publishes public ports (`80/tcp`, `443/tcp`, `443/udp`).
  - Uptime Kuma (`3001`) and Beszel Hub (`8090`) remain isolated on the internal `infiax_monitor_net` bridge.
  - Beszel Agent communicates with Beszel Hub over a shared Unix domain socket (`/beszel_socket/beszel.sock`), opening **zero** public TCP ports on the host.
- **Oracle Cloud Firewall Safe**:
  - Never flushes `iptables`, never deletes `InstanceServices`, never enables `ufw`, and never saves transient Docker chains into `/etc/iptables/rules.v4`.
- **Polished Terminal Management Interface (`monitor.sh`)**:
  - 18 interactive operations in an Infiax-branded (`#0a66c2`) terminal UI plus non-interactive CLI subcommands (`status`, `logs`, `backup`, `restore`, `health`, `preflight`, `update`, `uninstall --dry-run`).
- **Verified SQLite Backup & Restore System**:
  - Online SQLite snapshots (`sqlite3 .backup`), `PRAGMA integrity_check`, SHA-256 checksum verification, and automatic pre-restore/pre-update rollback snapshots.

---

## System Architecture

```text
                             Internet (HTTPS 443 / HTTP 80)
                                           │
                                           ▼
                      ┌─────────────────────────────────────────┐
                      │         Caddy Reverse Proxy             │
                      │   (Automatic Let's Encrypt TLS/HTTP3)   │
                      └───────────┬─────────────────┬───────────┘
                                  │                 │
            https://status.infiax.com         https://dev-monitor.infiax.com
            (Private Bridge :3001)            (Private Bridge :8090)
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
                                │           │ (VPS & Container  │
                                │           │     Metrics)      │
                                │           └───────────────────┘
                                │                     │
                                └──────────┬──────────┘
                                           │ Outbound HTTPS (443)
                                           ▼
                                ┌───────────────────────┐
                                │ Telegram Bot API      │
                                │ (Instant Alerting)    │
                                └───────────────────────┘
```

---

## Terminal Management Interface Preview

Run `sudo ./monitor.sh` (or `sudo infiax-monitor` after installation):

```text
  I N F I A X
  STATUS MONITOR (v1.0.0)
  ────────────────────────────────────
  Status: https://status.infiax.com   Beszel: https://dev-monitor.infiax.com
  Host:   oracle-vps (amd64)          RAM: 312/956 MiB
  ────────────────────────────────────

  SERVER
    01. System Information
    02. Preflight Checks

  INSTALLATION
    03. Install Monitoring Stack
    04. Configure Domains
    05. Configure Beszel Agent

  SERVICES
    06. Start Services
    07. Stop Services
    08. Restart Services
    09. Update Services
    10. Service Status
    11. View Logs

  NOTIFICATIONS
    12. Telegram Setup Guide
    13. Test Notifications

  MAINTENANCE
    14. Backup Data
    15. Restore Backup
    16. Health Checks
    17. Troubleshooting

  REMOVAL
    18. Uninstall Monitoring Stack

    00. Exit
  ────────────────────────────────────
  Select option [00-18]:
```

---

## Supported Operating Systems & Resource Requirements

| Component | Supported / Recommended |
| :--- | :--- |
| **Operating System** | Ubuntu Server 22.04 LTS (`jammy`) — also compatible with Ubuntu 24.04 LTS |
| **CPU Architecture** | `amd64` (`x86_64`) and `arm64` (`aarch64`) — automatically detected |
| **Memory (RAM)** | Minimum ~950 MiB RAM (tested target: Oracle `VM.Standard.E2.1.Micro` with 956 MiB RAM) |
| **Swap Space** | 2 GiB – 4 GiB swap required on `< 2 GiB` RAM servers |
| **Disk Space** | Minimum 3 GB free disk space |

---

## DNS Configuration

Create two **DNS `A` records** pointing to your VPS public IPv4 (`129.213.54.54` for the Infiax production VPS) before running the installer:

| Hostname | Type | Target IPv4 | Service |
| :--- | :--- | :--- | :--- |
| `status.infiax.com` | `A` | `129.213.54.54` | Uptime Kuma |
| `dev-monitor.infiax.com` | `A` | `129.213.54.54` | Beszel Hub |

- **Use hyphens (`dev-monitor`), never underscores (`dev_monitor`)**.
- **Remove any conflicting IPv6 `AAAA` records** unless IPv6 is actively routed on your VPS, as Let's Encrypt prioritizes `AAAA` records during domain validation.

---

## Quick Start & Installation

> **Root Privileges Note**: Installing packages, managing Docker containers, reading `/opt/infiax-status-monitor/.env`, and running backups require `root` (`sudo`). Read-only preflight and dry-run commands can be inspected safely at any time.

```bash
git clone https://github.com/harindujayakody/status-monitor.git
cd status-monitor

# Optional: Run read-only preflight & dry-run check first
sudo bash install.sh --dry-run

# Run full interactive installation (deploys to /opt/infiax-status-monitor)
sudo bash install.sh
```

---

## CLI Automation Commands

In addition to the interactive menu (`sudo ./monitor.sh`), every operation can be run non-interactively:

```bash
sudo ./monitor.sh info                  # System & resource summary
sudo ./monitor.sh preflight             # DNS, port, resource & firewall checks
sudo ./monitor.sh status                # Container status & memory usage
sudo ./monitor.sh logs                  # View stack container logs
sudo ./monitor.sh logs caddy 100        # View last 100 lines of Caddy logs
sudo ./monitor.sh backup                # Create verified SQLite + config backup
sudo ./monitor.sh backup --list         # List available backup archives
sudo ./monitor.sh restore               # Interactive verified restore
sudo ./monitor.sh update                # Pre-backup, pull, and recreate containers
sudo ./monitor.sh health                # Comprehensive stack health check
sudo ./monitor.sh troubleshoot          # Automated root-cause diagnostics
sudo ./monitor.sh uninstall --dry-run   # Safe deletion preview without changes
```

---

## Beszel Agent Pairing

1. During `install.sh`, once Beszel Hub starts and generates its ED25519 keypair in `/opt/infiax-status-monitor/data/beszel`, the installer automatically syncs the public key into `BESZEL_AGENT_KEY` and starts `beszel-agent` listening on `/beszel_socket/beszel.sock`.
2. Open `https://dev-monitor.infiax.com`, create your admin account, and click **+ Add System**.
3. Set **Name** to your hostname (e.g., `infiax-vps`) and **Host / IP** to:
   ```text
   /beszel_socket/beszel.sock
   ```
4. Click **Add system**. Live CPU, RAM, swap, disk, network, and container metrics will appear immediately.
5. To manually update keys or configure a WebSocket token at any time, run `sudo ./monitor.sh beszel-agent` (Menu Option **05**).

---

## Telegram Notifications Setup

1. Run `sudo ./monitor.sh telegram` (Menu Option **12**) to walk through creating a bot with `@BotFather`, auto-detecting your Chat ID, and saving credentials securely to `/opt/infiax-status-monitor/.env` (`0600`).
2. Run `sudo ./monitor.sh test-telegram` (Menu Option **13**) to send and verify a live test message.
3. Follow the on-screen guide (or [docs/telegram.md](docs/telegram.md)) to enable native Telegram notifications inside **Uptime Kuma** (`Settings -> Notifications`) and **Beszel Hub** (`Settings -> Notifications` via `telegram://<TOKEN>@telegram?chats=<CHAT_ID>`).

> **Limitation on Self-Hosted Alerting**: A self-hosted VPS cannot send Telegram alerts if the VPS itself suffers a total power, kernel, or upstream network outage. Pair `https://status.infiax.com` with an external uptime ping service to detect complete host outages.

---

## Oracle Cloud Firewall & Security Notes

- Ensure your Oracle Cloud VCN Security List allows ingress on TCP `22` (SSH), TCP `80` (HTTP), and TCP/UDP `443` (HTTPS).
- The host's existing `iptables` configuration (`INPUT` rules and the `InstanceServices` chain) is preserved intact.
- `ufw` is kept inactive, and transient Docker chains are never written to `/etc/iptables/rules.v4`.
- Only `beszel-agent` mounts `/var/run/docker.sock:ro` (for container metrics). See [docs/security.md](docs/security.md) for full details.

---

## Backup, Restore, Update & Uninstall

- **Backups**: `sudo ./monitor.sh backup` performs online SQLite `.backup` snapshots, checks `PRAGMA integrity_check`, and verifies SHA-256 checksums in `/opt/infiax-status-monitor/backups`. See [docs/backup-restore.md](docs/backup-restore.md).
- **Updates**: `sudo ./monitor.sh update` creates a verified backup before pulling updated images and recreating containers.
- **Uninstallation**: `sudo ./uninstall.sh` supports **Mode 1 (Preserve Data)**, **Mode 2 (Full Removal)**, and `--dry-run`. See [docs/uninstall.md](docs/uninstall.md).

---

## Documentation Index

- [Installation Guide](docs/installation.md)
- [Configuration Reference](docs/configuration.md)
- [Telegram Notifications Guide](docs/telegram.md)
- [Security & Oracle Cloud Firewall Guide](docs/security.md)
- [Backup & Restore Guide](docs/backup-restore.md)
- [Safe Uninstallation Guide](docs/uninstall.md)
- [Troubleshooting Guide](docs/troubleshooting.md)

---

## License

Released under the [MIT License](LICENSE).
