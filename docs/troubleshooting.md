# Troubleshooting Guide

Run automated diagnostics at any time via:

```bash
sudo /opt/infiax-status-monitor/monitor.sh health
sudo /opt/infiax-status-monitor/monitor.sh troubleshoot
```

---

## 1. HTTPS Certificate Acquisition Fails in Caddy

### Symptoms
Browser shows `SSL_ERROR_INTERNAL_ERROR_ALERT` or connection refused on `https://status.infiax.com` or `https://dev-monitor.infiax.com`.

### Checklist & Remediation
1. **Check DNS `A` Records**:
   Run `sudo ./monitor.sh preflight` and verify that both `status.infiax.com` and `dev-monitor.infiax.com` resolve to `129.213.54.54`.
2. **Check for Conflicting IPv6 `AAAA` Records**:
   If a domain has an `AAAA` record pointing to an unrouted IPv6 address or registrar parking page, Let's Encrypt HTTP-01 validation will fail. Remove any `AAAA` records in your DNS provider if IPv6 is not configured on your VPS.
3. **Check Hostname Syntax**:
   Ensure the domain uses hyphens (`dev-monitor.infiax.com`), never underscores (`dev_monitor.infiax.com`).
4. **Verify Oracle VCN Security List & `iptables`**:
   Confirm TCP ports `80` and `443` are open in both the Oracle Cloud VCN Ingress Security Rules and host `iptables INPUT` chain.
5. **Inspect Caddy Logs**:
   ```bash
   sudo ./monitor.sh logs caddy
   ```

---

## 2. Beszel Agent Shows "Offline" in Beszel Hub

### Symptoms
The system added in Beszel Hub stays red (`Offline`).

### Checklist & Remediation
1. **Verify the Host / IP Path in Beszel Hub UI**:
   Because Beszel Hub and Beszel Agent communicate over a shared Unix domain socket to avoid exposing TCP port `45876`, the system's **Host / IP** field in Beszel Hub must be set to:
   ```text
   /beszel_socket/beszel.sock
   ```
   *(Do not enter `localhost` or `127.0.0.1`, because `beszel` runs in an isolated bridge network).*
2. **Re-Sync the ED25519 Public Key**:
   Run:
   ```bash
   sudo ./monitor.sh beszel-agent
   ```
   Confirm that `BESZEL_AGENT_KEY` matches the `ssh-ed25519 ...` public key shown in the Beszel Hub **Add System** modal.
3. **Verify Socket Creation**:
   Check that `/opt/infiax-status-monitor/data/beszel-socket/beszel.sock` exists:
   ```bash
   sudo ./monitor.sh health
   ```

---

## 3. Caddy Returns `502 Bad Gateway` After Firewall Reload

### Symptoms
Caddy is running, but requests return `502 Bad Gateway` when proxying to `uptime-kuma:3001` or `beszel:8090`.

### Cause & Fix
On Oracle Cloud Ubuntu instances, running `sudo netfilter-persistent reload` *after* Docker has started reloads `/etc/iptables/rules.v4` and places Oracle's default `FORWARD` `REJECT` rule above Docker's `DOCKER-USER` / `DOCKER` chains.

Restarting the Docker service restores Docker's chains to the top of `FORWARD` without altering `/etc/iptables/rules.v4`:

```bash
sudo systemctl restart docker
sudo /opt/infiax-status-monitor/monitor.sh restart
```

---

## 4. High Memory Usage on Micro VPS (~956 MiB RAM)

1. Confirm that `4 GiB` swap is active using `sudo ./monitor.sh info`.
2. Ensure `UPTIME_KUMA_IMAGE` is set to `louislam/uptime-kuma:2.5.6-slim` (the `-slim` variant omits the bundled Chromium browser).
3. Ensure `BESZEL_DOCKER_IMAGE_CHECK=false` is set in `.env` so Beszel Agent does not periodically poll remote registries.
