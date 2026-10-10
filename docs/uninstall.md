# Safe Uninstallation Guide

**Infiax Status Monitor** provides a two-mode uninstaller with a non-destructive `--dry-run` preview.

---

## 1. Preview Uninstall Actions (`--dry-run`)

To inspect exactly which containers, networks, and directories would be affected without changing anything on your server:

```bash
sudo /opt/infiax-status-monitor/monitor.sh uninstall --dry-run
# or directly:
sudo bash /opt/infiax-status-monitor/uninstall.sh --dry-run
```

---

## 2. Mode 1 — Preserve Data (Recommended)

Removes the running containers (`infiax-caddy`, `infiax-uptime-kuma`, `infiax-beszel-hub`, `infiax-beszel-agent`), the `infiax_monitor_net` bridge network, and the `/usr/local/bin/infiax-monitor` symlink, while **preserving**:
- Uptime Kuma monitoring history (`data/uptime-kuma`)
- Beszel Hub metrics and ED25519 keys (`data/beszel`)
- Let's Encrypt TLS certificates (`data/caddy`)
- Environment configuration and secrets (`.env`)
- Backup archives (`backups/`)

```bash
sudo bash /opt/infiax-status-monitor/uninstall.sh --preserve-data
```

---

## 3. Mode 2 — Full Removal

Removes project containers, the project Docker network, application data (`data/`), and `.env`.

Before removing any data, Mode 2:
1. Displays a complete deletion scope preview.
2. Offers to create a final verified backup archive.
3. Requires explicit confirmation (and typing `DELETE` in interactive mode).
4. Prompts separately before deleting `/opt/infiax-status-monitor/backups`.

```bash
sudo bash /opt/infiax-status-monitor/uninstall.sh --full
```

---

## 4. What the Uninstaller Never Touches

- **Docker Engine & Compose**: Never uninstalls Docker or modifies `/etc/docker/daemon.json`.
- **Other Containers & Volumes**: Only removes resources belonging to `infiax-status-monitor`.
- **Oracle Cloud Firewall (`iptables`)**: Never modifies `iptables`, `InstanceServices`, or `ufw`.
- **SSH Keys & System Users**: Never alters `/root/.ssh`, `~/.ssh`, or SSH daemon settings.
