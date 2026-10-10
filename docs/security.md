# Security Architecture & Oracle Cloud Firewall Guide

**Infiax Status Monitor** is engineered with a defense-in-depth security posture tailored for Oracle Cloud Infrastructure (OCI) Ubuntu Server 22.04 LTS instances.

---

## 1. Network Exposure & Port Isolation

```text
Internet
   │
   │  Public Ports: TCP 80 (HTTP->HTTPS Redirect), TCP/UDP 443 (HTTPS / HTTP3)
   ▼
┌──────────────────────────────────────────────────────────┐
│ infiax-caddy (Caddy 2.11 Reverse Proxy)                  │
│   • Automatic Let's Encrypt TLS & HSTS security headers  │
└──────────────┬─────────────────────────────┬─────────────┘
               │ Private Bridge              │ Private Bridge
               │ (monitor_net :3001)         │ (monitor_net :8090)
               ▼                             ▼
┌──────────────────────────────┐  ┌────────────────────────┐
│ infiax-uptime-kuma           │  │ infiax-beszel-hub      │
│   • No host ports published  │  │   • No host ports      │
└──────────────────────────────┘  └──────────┬─────────────┘
                                             │ Shared Unix Socket
                                             │ (/beszel_socket/beszel.sock)
                                             ▼
                                  ┌────────────────────────┐
                                  │ infiax-beszel-agent    │
                                  │   • No TCP port bound  │
                                  │   • docker.sock :ro    │
                                  └────────────────────────┘
```

- **Zero Exposed Internal Ports**: Neither `uptime-kuma` (`3001`) nor `beszel` (`8090`) publishes ports to the host. They are reachable exclusively from `infiax-caddy` over the internal `infiax_monitor_net` Docker bridge.
- **Unix Domain Socket for Beszel Agent**: Although `beszel-agent` runs with `network_mode: host` so it can read host network interface counters, its `LISTEN` variable is set to `/beszel_socket/beszel.sock`. It **never binds TCP port `45876`** on the host network.

---

## 2. Oracle Cloud `iptables` & `InstanceServices` Protection

Oracle Cloud Ubuntu images use a preconfigured `iptables` ruleset managed by `iptables-persistent` / `netfilter-persistent`, including a critical custom chain named `InstanceServices` (which handles iSCSI root volume traffic and instance metadata on `169.254.0.0/16`).

### Strict Firewall Guarantees

Infiax Status Monitor **never**:
- Flushes `iptables` (`iptables -F` is never executed).
- Deletes or modifies the `InstanceServices` chain.
- Automatically enables `ufw` (enabling UFW on OCI can conflict with native `iptables` rules and lock out SSH).
- Removes or alters TCP port `22` (SSH) access.
- Runs `netfilter-persistent save` or `iptables-save > /etc/iptables/rules.v4` while Docker is running (which would otherwise bake transient `DOCKER` chains into persistent boot rules).

### `FORWARD` Chain Ordering Note

When Docker Engine starts, it inserts `DOCKER-USER` and `DOCKER` rules at the top of the `FORWARD` chain so containers on `infiax_monitor_net` can communicate. If an administrator manually runs `sudo netfilter-persistent reload` *after* Docker has started, Oracle's default `FORWARD` `REJECT` rule may be placed above the `DOCKER` chain.
- Menu Option **17 (Troubleshooting)** automatically detects this condition and instructs you to run `sudo systemctl restart docker` to restore proper chain order without modifying `/etc/iptables/rules.v4`.

---

## 3. Docker Socket (`docker.sock`) Security Implications

To display per-container CPU, memory, and status metrics inside Beszel Hub, `infiax-beszel-agent` mounts `/var/run/docker.sock:/var/run/docker.sock:ro`.

- **Scope Restriction**: Only `beszel-agent` mounts `docker.sock`. Caddy, Uptime Kuma, and Beszel Hub do **not** have access to the Docker socket.
- **Read-Only Mount & Hardening**: The socket is mounted `:ro` and all containers enforce `security_opt: ["no-new-privileges:true"]`.
- **Disabling Container Metrics (Optional)**: If you prefer not to grant `beszel-agent` access to `docker.sock`, remove the `/var/run/docker.sock` volume line from `compose.yaml` and set `DOCKER_HOST=""` in `.env`. Host CPU, RAM, swap, disk, and network monitoring will continue to work normally.

---

## 4. Secret & File Permission Protection

- `/opt/infiax-status-monitor/.env` is enforced at `0600` (`-rw-------`) so only `root` can read tokens or keys.
- `/opt/infiax-status-monitor/backups` and all `.tar.gz` / `.sha256` files are enforced at `0700` / `0600`.
- `.gitignore` explicitly blocks `.env`, `*.key`, `*.pem`, `ssh-key*`, SQLite databases, and backups from ever being committed to Git.
