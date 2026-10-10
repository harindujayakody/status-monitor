# Installation Guide

This guide walks you through deploying **Infiax Status Monitor** on Ubuntu Server 22.04 LTS (AMD64 or ARM64), including low-memory Oracle Cloud micro instances (`VM.Standard.E2.1.Micro`).

---

## 1. Prerequisites

| Requirement | Minimum Specification | Production Baseline (Oracle Micro) |
| :--- | :--- | :--- |
| **Operating System** | Ubuntu Server 22.04 LTS (`jammy`) | Ubuntu Server 22.04 LTS |
| **Architecture** | `amd64` (`x86_64`) or `arm64` (`aarch64`) | Auto-detected |
| **Memory (RAM)** | ~950 MiB | 956 MiB RAM |
| **Swap Space** | 2 GiB (4 GiB recommended) | 4 GiB Swap configured |
| **Disk Space** | 3 GB free | ~49 GB boot volume |
| **Public Ports** | TCP `22` (SSH), TCP `80` (HTTP), TCP/UDP `443` (HTTPS) | VCN Security List + `iptables` |
| **Privileges** | `root` (`sudo`) required for installation | `sudo bash install.sh` |

---

## 2. Configure DNS Records First

Before running the installer, create two **DNS `A` records** pointing to your VPS public IPv4 address (`129.213.54.54` for the Infiax production server):

| Host / Subdomain | Record Type | Value (Target IPv4) | Purpose |
| :--- | :--- | :--- | :--- |
| `status.infiax.com` | `A` | `129.213.54.54` | Uptime Kuma Status Page & Dashboard |
| `dev-monitor.infiax.com` | `A` | `129.213.54.54` | Beszel Hub Server Metrics Dashboard |

> **Important DNS Notes:**
> 1. Always use a hyphen (`dev-monitor`), **never an underscore (`dev_monitor`)**. Underscores violate RFC 1123 hostname rules and are rejected by Let's Encrypt ACME certificate authorities.
> 2. Ensure there are **no conflicting IPv6 `AAAA` records** on either subdomain unless IPv6 is actively routed to your VPS. Let's Encrypt prefers IPv6 when an `AAAA` record exists.

---

## 3. One-Click Installation

Clone the repository and execute `install.sh` with `sudo`:

```bash
git clone https://github.com/harindujayakody/status-monitor.git
cd status-monitor
sudo bash install.sh
```

### Dry-Run Preview (Read-Only)

To execute all 11 preflight checks (OS, architecture, RAM/swap, disk, DNS `A`/`AAAA`, port 80/443 availability, and Oracle Cloud `iptables` inspection) without making any changes:

```bash
sudo bash install.sh --dry-run
```

### Non-Interactive Installation

For automated provisioning with custom domains:

```bash
sudo bash install.sh --yes \
  --status-domain status.infiax.com \
  --beszel-domain dev-monitor.infiax.com \
  --acme-email admin@infiax.com
```

---

## 4. What the Installer Does

1. **Verifies Root & System Compatibility**: Confirms UID 0, Ubuntu 22.04+, `amd64`/`arm64`, RAM/swap, and free disk space.
2. **Validates Networking & Firewall Readiness**: Checks DNS `A`/`AAAA` resolution, ensures TCP 80/443 are free, and inspects Oracle Cloud `iptables` (`InstanceServices`, `INPUT`) in read-only mode.
3. **Installs Host Dependencies & Docker Engine**: Installs `curl`, `gnupg`, `dnsutils`, `jq`, `sqlite3`, `tar`, and official `docker-ce` + `docker-compose-plugin`.
4. **Prepares `/opt/infiax-status-monitor`**: Separates configuration (`.env` with `0600` permissions), persistent application data (`data/`), backups (`backups/`), and logs (`logs/`).
5. **Starts & Verifies the Stack**: Launches Caddy, Uptime Kuma, Beszel Hub, and Beszel Agent, automatically syncs the local Beszel Hub ED25519 public key, and runs health checks.
6. **Installs CLI Shortcut**: Links `/usr/local/bin/infiax-monitor` so you can launch the management UI from anywhere via `sudo infiax-monitor`.

---

## 5. Post-Installation Steps

1. **Create Admin Accounts Immediately**:
   - Open `https://status.infiax.com` and create your Uptime Kuma administrator account.
   - Open `https://dev-monitor.infiax.com` and create your Beszel Hub administrator account.
2. **Pair the Local Beszel Agent**:
   - In Beszel Hub, click **+ Add System**.
   - Enter Name: `infiax-vps` (or your hostname) and **Host / IP**: `/beszel_socket/beszel.sock`.
   - If you also want token authentication or key updates, run `sudo ./monitor.sh` -> **Option 05 (Configure Beszel Agent)**.
3. **Configure Telegram Alerts**:
   - Run `sudo ./monitor.sh` -> **Option 12 (Telegram Setup Guide)** and **Option 13 (Test Notifications)**.
