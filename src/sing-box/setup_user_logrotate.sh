#!/bin/bash

set -e

SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
ROTATE_SCRIPT_SRC="$(dirname "$0")/rotate_logs.sh"
ROTATE_SCRIPT_DST="$INSTALL_DIR/sing-box-log-rotate"

SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_UNIT="$SYSTEMD_DIR/${SERVICE_NAME}-log-rotate.service"
TIMER_UNIT="$SYSTEMD_DIR/${SERVICE_NAME}-log-rotate.timer"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

if ! command -v systemctl >/dev/null 2>&1; then
    error "systemctl not found. user timer cannot be configured."
    exit 1
fi

if [ ! -f "$ROTATE_SCRIPT_SRC" ]; then
    error "Rotate script not found: $ROTATE_SCRIPT_SRC"
    exit 1
fi

mkdir -p "$INSTALL_DIR"
mkdir -p "$SYSTEMD_DIR"

install -m 755 "$ROTATE_SCRIPT_SRC" "$ROTATE_SCRIPT_DST"

cat > "$SERVICE_UNIT" <<EOF
[Unit]
Description=Rotate sing-box file logs in user workspace

[Service]
Type=oneshot
ExecStart=$ROTATE_SCRIPT_DST
EOF

cat > "$TIMER_UNIT" <<EOF
[Unit]
Description=Periodic sing-box file log rotation

[Timer]
OnCalendar=hourly
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now "${SERVICE_NAME}-log-rotate.timer"

log "User log rotation timer configured: $TIMER_UNIT"
log "Check timer status: systemctl --user status ${SERVICE_NAME}-log-rotate.timer"
