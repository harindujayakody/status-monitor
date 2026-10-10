#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Official Docker Engine & Compose v2 Installer
# ==============================================================================
# Installs required host dependencies and Docker Engine + Docker Compose plugin
# from the official Docker APT repository for Ubuntu Server (amd64 / arm64).
# Preserves Oracle Cloud iptables rules (InstanceServices, INPUT, FORWARD).
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${SCRIPT_DIR}/common.sh"

install_host_dependencies() {
    require_root
    print_section "INSTALLING SYSTEM DEPENDENCIES"

    local missing_pkgs=()
    local pkg
    for pkg in ca-certificates curl gnupg lsb-release dnsutils jq sqlite3 tar git; do
        if ! dpkg -s "${pkg}" >/dev/null 2>&1; then
            missing_pkgs+=("${pkg}")
        fi
    done

    if (( ${#missing_pkgs[@]} == 0 )); then
        msg_ok "All required host packages (curl, gnupg, dnsutils, jq, sqlite3, tar) are already installed."
        return 0
    fi

    msg_info "Installing missing host packages: ${missing_pkgs[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends "${missing_pkgs[@]}"
    msg_ok "Host dependencies installed successfully."
}

configure_docker_daemon_defaults() {
    local daemon_file="/etc/docker/daemon.json"
    if [[ -f "${daemon_file}" ]]; then
        msg_info "Existing ${daemon_file} found; preserving existing Docker daemon configuration."
        return 0
    fi

    mkdir -p /etc/docker
    cat > "${daemon_file}" <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF
    chmod 644 "${daemon_file}"
    msg_ok "Configured /etc/docker/daemon.json with log rotation and live-restore."
}

verify_firewall_integrity_post_docker() {
    if ! command -v iptables >/dev/null 2>&1 || [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        return 0
    fi

    local ipt_out
    ipt_out="$(iptables -S 2>/dev/null || true)"
    if [[ "${ipt_out}" == *"InstanceServices"* ]]; then
        msg_ok "Verified Oracle Cloud 'InstanceServices' chain remains intact after Docker setup."
    fi
    if [[ "${ipt_out}" == *"--dport 22 "* ]]; then
        msg_ok "Verified SSH port 22 rule remains active in iptables INPUT chain."
    fi
    msg_info "Note: Transient Docker chains are managed in-memory by dockerd and are NOT written to /etc/iptables/rules.v4."
}

install_docker_engine() {
    require_root
    print_section "DOCKER ENGINE & COMPOSE SETUP"

    if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        msg_ok "Docker Engine and Docker Compose v2 are already installed."
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable --now docker >/dev/null 2>&1 || true
        fi
        verify_firewall_integrity_post_docker
        return 0
    fi

    local os_id
    os_id="$(detect_os_id)"
    if [[ "${os_id}" != "ubuntu" && "${os_id}" != "debian" ]]; then
        msg_error "Automated Docker APT installation supports Ubuntu/Debian (detected '${os_id}')."
        return 1
    fi

    install_host_dependencies

    msg_info "Setting up official Docker APT repository keyring..."
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
        curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
    fi

    local deb_arch codename
    deb_arch="$(dpkg --print-architecture)"
    # shellcheck disable=SC1091
    codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-jammy}")"

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${deb_arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${os_id} ${codename} stable
EOF
    chmod 644 /etc/apt/sources.list.d/docker.list

    configure_docker_daemon_defaults

    msg_info "Installing docker-ce, docker-ce-cli, containerd.io, and docker-compose-plugin..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    if command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now docker
    fi

    if docker --version >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
        msg_ok "Docker installed: $(docker --version)"
        msg_ok "Docker Compose installed: $(docker compose version)"
    else
        msg_error "Docker installation completed but verification failed."
        return 1
    fi

    verify_firewall_integrity_post_docker
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    setup_traps
    install_docker_engine "$@"
fi
