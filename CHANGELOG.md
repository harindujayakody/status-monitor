# Changelog

All notable changes to **Infiax Status Monitor** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-11

### Added
- **One-Click Production Installer (`install.sh`)**: Idempotent, low-memory-aware installer for Ubuntu Server 22.04 LTS (AMD64 & ARM64) deploying to `/opt/infiax-status-monitor`.
- **Interactive Terminal Management Interface (`monitor.sh`)**: Full 18-option Infiax-branded TUI (`#0a66c2`) with non-interactive CLI subcommands (`status`, `logs`, `backup`, `restore`, `health`, `preflight`, `update`, `uninstall --dry-run`, `--help`, `--version`).
- **Docker Compose Stack (`compose.yaml`)**: Version-pinned multi-arch services for Caddy (`2.11.7-alpine`), Uptime Kuma (`2.5.6-slim`), Beszel Hub (`0.21.0`), and Beszel Agent (`0.21.0`).
- **Reverse Proxy & Automatic TLS (`Caddyfile`)**: Automatic Let's Encrypt HTTPS, WebSocket support, security headers, log rotation, and zero exposed internal application ports.
- **Secure Local Beszel Agent Integration (`scripts/beszel-agent.sh`)**: Unix domain socket communication (`/beszel_socket/beszel.sock`) between Beszel Hub and Beszel Agent so no public agent TCP port is opened on the host.
- **Oracle Cloud Firewall Preservation (`scripts/preflight.sh`, `scripts/docker-install.sh`)**: Read-only verification of `iptables` (`INPUT`, `FORWARD`, `InstanceServices`), ensuring UFW is never auto-enabled and transient Docker chains are never saved to `/etc/iptables/rules.v4`.
- **Guided Telegram Alerting (`scripts/telegram.sh`)**: Interactive BotFather token & Chat ID configuration, live Telegram Bot API verification, test alert delivery, and native Shoutrrr URL generation for Beszel Hub.
- **Verified Backup & Restore System (`scripts/backup.sh`, `scripts/restore.sh`)**: Online SQLite snapshots, SHA-256 checksum verification, archive structure testing, retention pruning, and pre-restore rollback snapshots.
- **Safe Two-Mode Uninstaller (`uninstall.sh`, `scripts/uninstall.sh`)**: Supports Mode 1 (Preserve Data), Mode 2 (Full Removal with pre-deletion backup prompt), and `--dry-run`.
- **Automated Quality Assurance**: Test suites (`tests/`) and GitHub Actions workflow (`.github/workflows/validate.yml`).
