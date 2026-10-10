# Backup & Restore Guide

**Infiax Status Monitor** includes a verified, SQLite-aware backup and restore system designed to protect monitoring history, configuration, and TLS certificates.

---

## 1. Creating a Backup

 requires `root` (`sudo`) privileges to read protected data directories and `.env`:

```bash
sudo /opt/infiax-status-monitor/monitor.sh backup
```

Or select **14. Backup Data** from the interactive `sudo ./monitor.sh` menu.

### How Backups Work

1. **Online SQLite Snapshot**: For every `.db` file under `data/` (including Uptime Kuma's `kuma.db` and Beszel Hub's `data.db` / `auxiliary.db`), the backup script executes `sqlite3 <db> ".backup '<staging_db>'"` so active WAL transactions are safely checkpointed without stopping your monitoring containers.
2. **Database Integrity Check**: Every staged SQLite database is tested with `PRAGMA integrity_check;` before packaging.
3. **Manifest & Compression**: Configuration (`.env`, `compose.yaml`, `Caddyfile`), application data (`data/`), and `backup-manifest.json` are packaged into `/opt/infiax-status-monitor/backups/infiax-backup-YYYYMMDD-HHMMSS.tar.gz` with `0600` permissions.
4. **Cryptographic & Structural Verification**: A `.sha256` checksum file is generated and verified alongside `tar -tzf` structural validation before the backup is reported as successful.
5. **Automatic Retention Pruning**: Old archives beyond `BACKUP_RETENTION_COUNT` (default `7` in `.env`) are automatically pruned.

---

## 2. Listing Available Backups

```bash
sudo /opt/infiax-status-monitor/monitor.sh backup --list
```

---

## 3. Restoring from a Backup

```bash
sudo /opt/infiax-status-monitor/monitor.sh restore
```

Or pass a specific archive filename/path:

```bash
sudo /opt/infiax-status-monitor/monitor.sh restore infiax-backup-20261011-030000.tar.gz
```

### Safe Restore Workflow

1. **Pre-Restore Verification**: The archive's SHA-256 checksum, `tar.gz` structure, `backup-manifest.json`, and staged SQLite `PRAGMA integrity_check;` results are verified **before** any running service is stopped or any file is overwritten.
2. **Explicit Confirmation**: Prompts for confirmation before proceeding.
3. **Automatic Rollback Snapshot**: Creates a fresh safety backup of the current state before replacing `data/` and `.env`.
4. **Service Restart**: Stops containers cleanly, restores `data/` and configuration with `0600` permissions on `.env`, and restarts the stack.
