# Configuration Reference

All runtime settings for **Infiax Status Monitor** are stored in `/opt/infiax-status-monitor/.env` with strict `0600` (`-rw-------`) file permissions.

---

## 1. Runtime Directory Layout

```text
/opt/infiax-status-monitor/
├── .env                       # Protected environment configuration (mode 0600)
├── compose.yaml               # Docker Compose stack definition
├── Caddyfile                  # Caddy reverse proxy & automatic TLS config
├── install.sh                 # Installer
├── monitor.sh                 # Terminal Management UI & CLI
├── uninstall.sh               # Safe Uninstaller
├── scripts/                   # Modular operational scripts
├── docs/                      # Documentation
├── data/                      # Persistent application state (mode 0750)
│   ├── uptime-kuma/           # Uptime Kuma SQLite database (kuma.db) & settings
│   ├── beszel/                # Beszel Hub SQLite databases & ED25519 keypair
│   ├── beszel-agent/          # Beszel Agent system fingerprint state
│   ├── beszel-socket/         # Shared Unix socket (/beszel_socket/beszel.sock)
│   └── caddy/                 # Let's Encrypt TLS certificates & rotated access logs
├── backups/                   # Verified .tar.gz archives & .sha256 files (mode 0700)
└── logs/                      # Plain-text operational logs (monitor.log)
```

---

## 2. Environment Variables (`.env`)

| Variable | Default Value | Description |
| :--- | :--- | :--- |
| `COMPOSE_PROJECT_NAME` | `infiax-status-monitor` | Stable Docker Compose project identifier |
| `TZ` | `UTC` | Container timezone |
| `STATUS_DOMAIN` | `status.infiax.com` | Public FQDN for Uptime Kuma |
| `BESZEL_DOMAIN` | `dev-monitor.infiax.com` | Public FQDN for Beszel Hub |
| `ACME_EMAIL` | `admin@infiax.com` | Email for Let's Encrypt TLS registration |
| `SERVER_IPV4` | `129.213.54.54` | Expected public IPv4 used during DNS preflight |
| `CADDY_IMAGE` | `caddy:2.11.7-alpine` | Pinned multi-arch Caddy image |
| `UPTIME_KUMA_IMAGE` | `louislam/uptime-kuma:2.5.6-slim` | Pinned lightweight Uptime Kuma v2 image (no Chromium bloat) |
| `BESZEL_HUB_IMAGE` | `henrygd/beszel:0.21.0` | Pinned multi-arch Beszel Hub image |
| `BESZEL_AGENT_IMAGE` | `henrygd/beszel-agent:0.21.0` | Pinned multi-arch Beszel Agent image |
| `BESZEL_APP_URL` | `https://dev-monitor.infiax.com` | Base URL used by Beszel Hub for alert links |
| `BESZEL_AGENT_LISTEN` | `/beszel_socket/beszel.sock` | Unix domain socket path shared with Beszel Hub |
| `BESZEL_AGENT_KEY` | *(auto-synced / user-set)* | Beszel Hub `ssh-ed25519` public key |
| `BESZEL_AGENT_TOKEN` | *(optional)* | Beszel Agent token for WebSocket registration |
| `BESZEL_DOCKER_IMAGE_CHECK` | `false` | Disables periodic registry polling to save CPU/RAM |
| `CADDY_MEM_LIMIT` | `128m` | Memory limit for Caddy container |
| `UPTIME_KUMA_MEM_LIMIT` | `384m` | Memory limit for Uptime Kuma container |
| `UPTIME_KUMA_NODE_MAX_OLD_SPACE` | `256` | Node.js V8 max old space size (MiB) |
| `BESZEL_HUB_MEM_LIMIT` | `192m` | Memory limit for Beszel Hub container |
| `BESZEL_AGENT_MEM_LIMIT` | `128m` | Memory limit for Beszel Agent container |
| `BACKUP_RETENTION_COUNT` | `7` | Number of verified backups to retain automatically |

---

## 3. Changing Domains After Installation

To update domains interactively with automatic syntax validation, DNS `A`/`AAAA` verification, and live Caddy reload:

```bash
sudo /opt/infiax-status-monitor/monitor.sh domains
```

Or select **04. Configure Domains** from the interactive `sudo ./monitor.sh` menu.

---

## 4. Pairing Beszel Agent

Because `beszel` (Hub) and `beszel-agent` share the `/opt/infiax-status-monitor/data/beszel-socket:/beszel_socket` volume:

1. `beszel-agent` listens on the Unix domain socket `/beszel_socket/beszel.sock` instead of opening TCP port `45876` on the host.
2. `beszel-agent` uses `network_mode: host` (required by Beszel to read host network interface bandwidth counters) while exposing **zero** TCP listening ports.
3. In the Beszel Hub web UI (`https://dev-monitor.infiax.com`), add your system with:
   - **Host / IP**: `/beszel_socket/beszel.sock`
4. Run `sudo /opt/infiax-status-monitor/monitor.sh beszel-agent` (Menu Option 05) to view or update `BESZEL_AGENT_KEY` and `BESZEL_AGENT_TOKEN`.
