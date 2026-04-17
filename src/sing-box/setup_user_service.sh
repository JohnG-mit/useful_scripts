#!/bin/bash

set -e

SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
BIN_PATH="$INSTALL_DIR/sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME.service"

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
    error "systemctl not found. systemd user service cannot be configured."
    exit 1
fi

if [ ! -x "$BIN_PATH" ]; then
    error "sing-box binary not found: $BIN_PATH"
    exit 1
fi

mkdir -p "$SYSTEMD_DIR"
mkdir -p "$WORK_DIR/ui"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
ExecStart=$BIN_PATH -D $WORK_DIR -C $WORK_DIR run
WorkingDirectory=$WORK_DIR
Restart=always
LimitNOFILE=infinity

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

log "User service is configured: $SERVICE_FILE"
log "Service status: systemctl --user status $SERVICE_NAME"
