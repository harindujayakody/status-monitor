#!/usr/bin/env bash
# ==============================================================================
# Infiax Status Monitor — Uninstaller Entrypoint
# ==============================================================================
# Usage:
#   sudo bash uninstall.sh                 # Interactive Mode 1 / Mode 2 prompt
#   sudo bash uninstall.sh --dry-run       # Safe deletion preview without changes
#   sudo bash uninstall.sh --preserve-data # Mode 1: Remove containers, keep data
#   sudo bash uninstall.sh --full          # Mode 2: Full project removal
# ==============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "${ROOT_DIR}/scripts/common.sh"
# shellcheck source=scripts/uninstall.sh
source "${ROOT_DIR}/scripts/uninstall.sh"

show_uninstall_help() {
    print_banner "Safe Uninstaller"
    cat <<'EOF'
Usage:
  sudo ./uninstall.sh [OPTIONS]

Options:
  --dry-run, -n       Preview resources to be removed without making changes
  --preserve-data     Mode 1: Remove containers/network, preserve data & certs
  --full              Mode 2: Remove containers, network, data, and configs
  --delete-backups    In --full mode, also delete backup archives
  --yes, -y           Non-interactive confirmation
  --help, -h          Show this help message
EOF
}

main() {
    setup_traps
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_uninstall_help
        exit 0
    fi
    print_banner "Safe Uninstaller"
    run_uninstaller "$@"
}

main "$@"
