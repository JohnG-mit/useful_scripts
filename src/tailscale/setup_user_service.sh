#!/bin/bash

set -e

SERVICE_NAME="tailscaled"
INSTALL_DIR="$HOME/bin"
BIN_PATH="$INSTALL_DIR/tailscaled"
WORK_DIR="$HOME/service/tailscale"
STATE_DIR="$WORK_DIR/state"
SOCKET_PATH="$WORK_DIR/tailscaled.sock"
LOG_FILE="$WORK_DIR/tailscaled.log"
SYSTEMD_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME.service"
BASH_BIN="$(command -v bash || true)"

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
    error "tailscaled binary not found: $BIN_PATH"
    exit 1
fi

if [ -z "$BASH_BIN" ]; then
    error "bash not found. It is required to launch tailscaled with file logging."
    exit 1
fi

mkdir -p "$SYSTEMD_DIR" "$WORK_DIR" "$STATE_DIR"
chmod 700 "$WORK_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Tailscale userspace daemon
Documentation=https://tailscale.com/docs/concepts/userspace-networking https://tailscale.com/docs/features/tailscale-ssh
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$BASH_BIN -lc 'exec "$BIN_PATH" --tun=userspace-networking --socket="$SOCKET_PATH" --statedir="$STATE_DIR" --socks5-server=127.0.0.1:1055 --outbound-http-proxy-listen=127.0.0.1:1055 >> "$LOG_FILE" 2>&1'
WorkingDirectory=$WORK_DIR
Restart=always
RestartSec=5
LimitNOFILE=infinity

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user restart "$SERVICE_NAME"

log "User service is configured: $SERVICE_FILE"
log "Service status: systemctl --user status $SERVICE_NAME"
