#!/bin/bash

set -e

SERVICE_NAME="tailscaled"
INSTALL_DIR="$HOME/bin"
TAILSCALE_BIN="$INSTALL_DIR/tailscale"
WORK_DIR="$HOME/service/tailscale"
SOCKET_PATH="$WORK_DIR/tailscaled.sock"
LOG_FILE="$WORK_DIR/tailscaled.log"
CRON_ENSURE="$INSTALL_DIR/tailscale-cron-ensure"

export PATH="$INSTALL_DIR:$PATH"

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

show_help() {
    cat <<EOF
Usage: ts [command] [args]

Commands:
    s, status       Show Tailscale status
    ip              Show Tailscale IP addresses
    up              Run tailscale up --ssh
    down            Bring Tailscale down
    ssh             Run tailscale ssh
    r, restart      Restart tailscaled via systemd or cron fallback
    logs            Follow tailscaled file logs
    netcheck        Run Tailscale network diagnostics
    v, version      Show Tailscale version
    h, help         Show this help

Unknown commands are passed through to: tailscale --socket=$SOCKET_PATH
EOF
}

require_binary() {
    if [ ! -x "$TAILSCALE_BIN" ]; then
        error "tailscale binary not found: $TAILSCALE_BIN"
        error "Please run: bash src/tailscale/install.sh"
        exit 1
    fi
}

require_socket() {
    if [ ! -S "$SOCKET_PATH" ] && [ -x "$CRON_ENSURE" ]; then
        "$CRON_ENSURE" >/dev/null 2>&1 || true
        wait_for_socket 5 || true
    fi

    if [ ! -S "$SOCKET_PATH" ]; then
        error "tailscaled socket not found: $SOCKET_PATH"
        error "Please run: ts restart"
        exit 1
    fi
}

wait_for_socket() {
    local max_wait="${1:-20}"
    local waited=0

    while [ "$waited" -lt "$max_wait" ]; do
        if [ -S "$SOCKET_PATH" ]; then
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    return 1
}

tailscale_cmd() {
    require_binary
    require_socket
    "$TAILSCALE_BIN" --socket="$SOCKET_PATH" "$@"
}

show_status() {
    tailscale_cmd status
}

show_ip() {
    tailscale_cmd ip "$@"
}

tailscale_up() {
    tailscale_cmd up --ssh "$@"
}

tailscale_down() {
    tailscale_cmd down
}

tailscale_ssh() {
    if [ "$#" -eq 0 ]; then
        error "Missing SSH target. Example: ts ssh user@host"
        exit 1
    fi

    tailscale_cmd ssh "$@"
}

kill_socket_tailscaled() {
    local pid

    if command -v pgrep >/dev/null 2>&1; then
        for pid in $(pgrep -u "${USER:-$(id -un)}" -x tailscaled 2>/dev/null || true); do
            if ps -p "$pid" -o args= 2>/dev/null | grep -Fq -- "--socket=$SOCKET_PATH"; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        return
    fi

    if command -v pkill >/dev/null 2>&1; then
        pkill -u "${USER:-$(id -un)}" -f "tailscaled.*--socket=$SOCKET_PATH" 2>/dev/null || true
    fi
}

restart_service() {
    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log "Restarting $SERVICE_NAME via user systemd..."
        systemctl --user restart "$SERVICE_NAME"
        sleep 1

        if systemctl --user is-active --quiet "$SERVICE_NAME"; then
            log "$SERVICE_NAME restarted successfully"
            return
        fi

        error "$SERVICE_NAME failed to start after restart"
        systemctl --user status "$SERVICE_NAME" --no-pager || true
        exit 1
    fi

    if [ -x "$CRON_ENSURE" ]; then
        log "Restarting $SERVICE_NAME via cron fallback..."
        kill_socket_tailscaled
        sleep 1
        rm -f "$SOCKET_PATH"
        "$CRON_ENSURE"

        if wait_for_socket 20; then
            log "$SERVICE_NAME restarted successfully"
            return
        fi

        error "$SERVICE_NAME failed to start after cron fallback restart"
        exit 1
    fi

    error "No active user systemd service or cron fallback helper found."
    error "Please run: bash src/tailscale/install.sh"
    exit 1
}

follow_logs() {
    local lines="${1:-200}"

    if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
        lines=200
    fi

    if [ -f "$LOG_FILE" ]; then
        tail -n "$lines" -f "$LOG_FILE"
        return
    fi

    warn "File log not found, falling back to journalctl"
    journalctl --user -u "$SERVICE_NAME" -f
}

show_version() {
    require_binary
    "$TAILSCALE_BIN" version
}

main() {
    case "${1:-}" in
        "")
            show_help
            ;;
        s|status)
            show_status
            ;;
        ip)
            shift
            show_ip "$@"
            ;;
        up)
            shift
            tailscale_up "$@"
            ;;
        down)
            tailscale_down
            ;;
        ssh)
            shift
            tailscale_ssh "$@"
            ;;
        r|restart)
            restart_service
            ;;
        logs)
            shift
            follow_logs "${1:-200}"
            ;;
        netcheck)
            tailscale_cmd netcheck
            ;;
        v|version)
            show_version
            ;;
        h|help|-h|--help)
            show_help
            ;;
        *)
            tailscale_cmd "$@"
            ;;
    esac
}

main "$@"
