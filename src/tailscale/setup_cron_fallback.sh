#!/bin/bash

set -e

INSTALL_DIR="$HOME/bin"
ENSURE_SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/tailscale_cron_ensure.sh"
ENSURE_SCRIPT_DST="$INSTALL_DIR/tailscale-cron-ensure"
ROTATE_SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/rotate_logs.sh"
ROTATE_SCRIPT_DST="$INSTALL_DIR/tailscale-log-rotate"

BEGIN_MARKER="# BEGIN useful_scripts tailscale cron fallback"
END_MARKER="# END useful_scripts tailscale cron fallback"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

require_command() {
    local cmd="$1"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Missing command: $cmd"
        exit 1
    fi
}

remove_cron_block() {
    local current_cron
    local new_cron

    if ! command -v crontab >/dev/null 2>&1; then
        return 0
    fi

    current_cron="$(mktemp)"
    new_cron="$(mktemp)"

    crontab -l > "$current_cron" 2>/dev/null || true

    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$current_cron" > "$new_cron"

    crontab "$new_cron"
    rm -f "$current_cron" "$new_cron"
    log "Cron fallback block removed if present."
}

install_cron_block() {
    local current_cron
    local new_cron

    current_cron="$(mktemp)"
    new_cron="$(mktemp)"

    crontab -l > "$current_cron" 2>/dev/null || true

    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin { skip = 1; next }
        $0 == end { skip = 0; next }
        !skip { print }
    ' "$current_cron" > "$new_cron"

    {
        echo "$BEGIN_MARKER"
        echo "SHELL=/bin/bash"
        echo "PATH=$INSTALL_DIR:/usr/local/bin:/usr/bin:/bin"
        echo '* * * * "$HOME/bin/tailscale-cron-ensure" >/dev/null 2>&1'
        echo '@hourly "$HOME/bin/tailscale-log-rotate" >/dev/null 2>&1'
        echo "$END_MARKER"
    } >> "$new_cron"

    crontab "$new_cron"
    rm -f "$current_cron" "$new_cron"
    log "Cron fallback entries installed."
}

disable_user_systemd_units() {
    if ! command -v systemctl >/dev/null 2>&1; then
        return 0
    fi

    systemctl --user disable --now tailscaled 2>/dev/null || true
    systemctl --user disable --now tailscale-log-rotate.timer 2>/dev/null || true
    systemctl --user stop tailscale-log-rotate.service 2>/dev/null || true
    log "User systemd Tailscale units disabled if present."
}

if [ "${1:-}" = "--remove" ]; then
    remove_cron_block
    exit 0
fi

require_command crontab
require_command install
require_command awk
require_command mktemp
require_command nohup

if [ ! -f "$ENSURE_SCRIPT_SRC" ]; then
    error "Cron ensure script not found: $ENSURE_SCRIPT_SRC"
    exit 1
fi

if [ ! -f "$ROTATE_SCRIPT_SRC" ]; then
    error "Rotate script not found: $ROTATE_SCRIPT_SRC"
    exit 1
fi

mkdir -p "$INSTALL_DIR"
install -m 755 "$ENSURE_SCRIPT_SRC" "$ENSURE_SCRIPT_DST"
install -m 755 "$ROTATE_SCRIPT_SRC" "$ROTATE_SCRIPT_DST"

install_cron_block
disable_user_systemd_units

"$ENSURE_SCRIPT_DST"

warn "Cron fallback is active. systemctl --user status tailscaled is not authoritative in this mode."
