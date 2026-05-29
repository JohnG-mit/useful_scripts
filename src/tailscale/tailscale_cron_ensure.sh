#!/bin/bash

set -e

INSTALL_DIR="$HOME/bin"
BIN_PATH="$INSTALL_DIR/tailscaled"
WORK_DIR="$HOME/service/tailscale"
STATE_DIR="$WORK_DIR/state"
SOCKET_PATH="$WORK_DIR/tailscaled.sock"
LOG_FILE="$WORK_DIR/tailscaled.log"

error() {
    echo "[ERROR] $1" >&2
}

is_tailscaled_running() {
    local pid

    if command -v pgrep >/dev/null 2>&1; then
        for pid in $(pgrep -u "${USER:-$(id -un)}" -x tailscaled 2>/dev/null || true); do
            if ps -p "$pid" -o args= 2>/dev/null | grep -Fq -- "--socket=$SOCKET_PATH"; then
                return 0
            fi
        done
        return 1
    fi

    ps -u "${USER:-$(id -un)}" -o args= 2>/dev/null \
        | grep -F "tailscaled" \
        | grep -Fq -- "--socket=$SOCKET_PATH"
}

wait_for_socket() {
    local waited=0

    while [ "$waited" -lt 20 ]; do
        if [ -S "$SOCKET_PATH" ]; then
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

if [ ! -x "$BIN_PATH" ]; then
    error "tailscaled binary not found: $BIN_PATH"
    exit 1
fi

if ! command -v nohup >/dev/null 2>&1; then
    error "nohup not found. It is required for cron fallback mode."
    exit 1
fi

mkdir -p "$WORK_DIR" "$STATE_DIR"
chmod 700 "$WORK_DIR" "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

if is_tailscaled_running; then
    exit 0
fi

if [ -S "$SOCKET_PATH" ]; then
    rm -f "$SOCKET_PATH"
fi

nohup "$BIN_PATH" \
    --tun=userspace-networking \
    --socket="$SOCKET_PATH" \
    --statedir="$STATE_DIR" \
    --socks5-server=127.0.0.1:1055 \
    --outbound-http-proxy-listen=127.0.0.1:1055 \
    >> "$LOG_FILE" 2>&1 &

disown "$!" 2>/dev/null || true

if ! wait_for_socket; then
    error "tailscaled did not create socket: $SOCKET_PATH"
    tail -n 80 "$LOG_FILE" >&2 || true
    exit 1
fi
