#!/bin/bash

set -e

INSTALL_DIR="$HOME/bin"
OPT_DIR="$HOME/opt/tailscale"
WORK_DIR="$HOME/service/tailscale"
SOCKET_PATH="$WORK_DIR/tailscaled.sock"
SERVICE_NAME="tailscaled"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETUP_SERVICE_SCRIPT="$SCRIPT_DIR/setup_user_service.sh"
SETUP_LOGROTATE_SCRIPT="$SCRIPT_DIR/setup_user_logrotate.sh"
SETUP_CRON_FALLBACK_SCRIPT="$SCRIPT_DIR/setup_cron_fallback.sh"
TS_SCRIPT="$SCRIPT_DIR/ts.sh"
SUPERVISOR_MODE="systemd"

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

get_default_shell_name() {
    basename "${SHELL:-sh}"
}

get_default_shell_rc() {
    local shell_name
    shell_name="$(get_default_shell_name)"

    case "$shell_name" in
        zsh)
            echo "$HOME/.zshrc"
            ;;
        bash)
            echo "$HOME/.bashrc"
            ;;
        fish)
            echo "$HOME/.config/fish/config.fish"
            ;;
        *)
            echo "$HOME/.profile"
            ;;
    esac
}

ensure_rc_file() {
    local rc_file="$1"
    local rc_dir

    rc_dir="$(dirname "$rc_file")"
    mkdir -p "$rc_dir"
    touch "$rc_file"
}

ensure_user_bin_path() {
    local rc_file
    local shell_name
    local path_line

    shell_name="$(get_default_shell_name)"
    rc_file="$(get_default_shell_rc)"

    ensure_rc_file "$rc_file"

    if [ "$shell_name" = "fish" ]; then
        path_line='set -gx PATH "$HOME/bin" $PATH'
    else
        path_line='export PATH="$HOME/bin:$PATH"'
    fi

    if grep -Fqx "$path_line" "$rc_file"; then
        log "$HOME/bin PATH entry already configured in $rc_file"
    else
        log "Adding $HOME/bin to PATH in $rc_file..."
        {
            echo ""
            echo "# user-local commands"
            if [ "$shell_name" = "fish" ]; then
                echo 'if not contains "$HOME/bin" $PATH'
                echo "    $path_line"
                echo "end"
            else
                echo "$path_line"
            fi
        } >> "$rc_file"
    fi

    if [[ ":$PATH:" != *":$HOME/bin:"* ]]; then
        export PATH="$HOME/bin:$PATH"
    fi
}

map_tailscale_arch() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l|armv6l)
            echo "arm"
            ;;
        i386|i686)
            echo "386"
            ;;
        *)
            error "Unsupported architecture: $arch"
            exit 1
            ;;
    esac
}

get_tailscale_version() {
    local ts_arch="$1"

    if [ -n "${TAILSCALE_VERSION:-}" ]; then
        echo "$TAILSCALE_VERSION"
        return
    fi

    curl -fsSL https://pkgs.tailscale.com/stable/ \
        | grep -oE "tailscale_[0-9]+\.[0-9]+\.[0-9]+_${ts_arch}\.tgz" \
        | sed -E "s/tailscale_([0-9]+\.[0-9]+\.[0-9]+)_${ts_arch}\.tgz/\1/" \
        | sort -V \
        | tail -n 1
}

install_tailscale_binary() {
    local ts_arch
    local ts_version
    local archive
    local tmp_dir
    local extracted_dir

    require_command curl
    require_command cut
    require_command grep
    require_command head
    require_command sed
    require_command sort
    require_command tar

    ts_arch="$(map_tailscale_arch)"
    ts_version="$(get_tailscale_version "$ts_arch")"

    if [ -z "$ts_version" ]; then
        error "Failed to detect latest Tailscale version for arch: $ts_arch"
        exit 1
    fi

    log "Installing Tailscale $ts_version for $ts_arch..."

    mkdir -p "$INSTALL_DIR" "$OPT_DIR"

    tmp_dir="$(mktemp -d)"

    archive="$tmp_dir/tailscale_${ts_version}_${ts_arch}.tgz"
    curl -fsSL -o "$archive" "https://pkgs.tailscale.com/stable/tailscale_${ts_version}_${ts_arch}.tgz"

    tar -xzf "$archive" -C "$tmp_dir"
    extracted_dir="$(tar -tf "$archive" | head -n 1 | cut -d/ -f1)"

    if [ ! -x "$tmp_dir/$extracted_dir/tailscale" ] || [ ! -x "$tmp_dir/$extracted_dir/tailscaled" ]; then
        error "Tailscale archive does not contain expected binaries"
        exit 1
    fi

    rm -rf "$OPT_DIR"/*
    cp -R "$tmp_dir/$extracted_dir"/. "$OPT_DIR"/

    install -m 755 "$tmp_dir/$extracted_dir/tailscale" "$INSTALL_DIR/tailscale"
    install -m 755 "$tmp_dir/$extracted_dir/tailscaled" "$INSTALL_DIR/tailscaled"

    rm -rf "$tmp_dir"

    "$INSTALL_DIR/tailscale" version
}

stop_existing_user_tailscaled() {
    local current_user
    local service_active="false"
    local process_exists="false"

    current_user="${USER:-$(id -un 2>/dev/null || echo user)}"

    if command -v systemctl >/dev/null 2>&1 && systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        service_active="true"
    fi

    if command -v pgrep >/dev/null 2>&1 && pgrep -u "$current_user" -x tailscaled >/dev/null 2>&1; then
        process_exists="true"
    fi

    if [ "$service_active" = "true" ]; then
        log "Stopping existing user-level tailscaled service..."
        systemctl --user stop "$SERVICE_NAME" || true
    fi

    if [ "$process_exists" = "true" ]; then
        warn "Terminating existing user-owned tailscaled process..."
        pkill -u "$current_user" -x tailscaled || true
    fi
}

install_ts_command() {
    if [ ! -f "$TS_SCRIPT" ]; then
        error "ts helper script not found: $TS_SCRIPT"
        exit 1
    fi

    log "Installing ts command to $INSTALL_DIR/ts..."
    install -m 755 "$TS_SCRIPT" "$INSTALL_DIR/ts"
}

select_supervisor() {
    local current_user
    current_user="${USER:-$(id -un 2>/dev/null || echo user)}"

    if [ "${TAILSCALE_FORCE_CRON:-}" = "1" ]; then
        warn "TAILSCALE_FORCE_CRON=1 is set. Using cron fallback supervisor."
        SUPERVISOR_MODE="cron"
        return
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        warn "systemctl not found. Using cron fallback supervisor."
        SUPERVISOR_MODE="cron"
        return
    fi

    if ! command -v loginctl >/dev/null 2>&1; then
        warn "loginctl not found. Using cron fallback supervisor."
        SUPERVISOR_MODE="cron"
        return
    fi

    log "Trying to enable linger for user: $current_user"
    if loginctl enable-linger "$current_user" >/dev/null 2>&1; then
        log "User linger is enabled. Using user-level systemd supervisor."
        SUPERVISOR_MODE="systemd"
    else
        warn "Failed to enable linger for $current_user. Using cron fallback supervisor."
        SUPERVISOR_MODE="cron"
    fi
}

remove_cron_fallback_if_possible() {
    if [ -f "$SETUP_CRON_FALLBACK_SCRIPT" ]; then
        bash "$SETUP_CRON_FALLBACK_SCRIPT" --remove || true
    fi
}

wait_for_socket() {
    local waited=0

    while [ "$waited" -lt 30 ]; do
        if [ -S "$SOCKET_PATH" ]; then
            return 0
        fi

        sleep 1
        waited=$((waited + 1))
    done

    error "tailscaled socket was not created: $SOCKET_PATH"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user status "$SERVICE_NAME" --no-pager || true
    fi
    if [ -f "$WORK_DIR/tailscaled.log" ]; then
        tail -n 80 "$WORK_DIR/tailscaled.log" || true
    fi
    exit 1
}

run_tailscale_up() {
    if "$INSTALL_DIR/tailscale" --socket="$SOCKET_PATH" status >/dev/null 2>&1; then
        log "Tailscale is already authenticated. Ensuring Tailscale SSH is enabled..."
        if "$INSTALL_DIR/tailscale" --socket="$SOCKET_PATH" set --ssh=true; then
            return
        fi

        warn "Failed to enable SSH with 'tailscale set'. Falling back to 'tailscale up --ssh'."
    fi

    log "Bringing Tailscale up with Tailscale SSH enabled..."
    log "If prompted, open the login URL in your browser and approve this device."

    "$INSTALL_DIR/tailscale" --socket="$SOCKET_PATH" up --ssh
}

print_connection_info() {
    local ts_ip
    local hostname_text

    ts_ip="$("$INSTALL_DIR/tailscale" --socket="$SOCKET_PATH" ip -4 2>/dev/null | head -n 1 || true)"
    hostname_text="$(hostname 2>/dev/null || echo host)"

    log "Tailscale userspace service is installed and started."
    if [ "$SUPERVISOR_MODE" = "systemd" ]; then
        log "Supervisor: systemd user service"
        log "Service status: systemctl --user status $SERVICE_NAME"
    else
        log "Supervisor: user crontab + nohup fallback"
        log "Cron entries: crontab -l | sed -n '/useful_scripts tailscale cron fallback/,+4p'"
    fi
    log "Logs: ts logs"
    log "CLI helper: ts status"

    if [ -n "$ts_ip" ]; then
        log "Tailscale IPv4: $ts_ip"
        log "From another tailnet device: ssh ${USER}@${ts_ip}"
    else
        warn "Tailscale IPv4 was not available yet. Run: ts ip"
    fi

    log "MagicDNS/host SSH example: tailscale ssh ${USER}@${hostname_text}"
}

main() {
    require_command uname
    require_command install

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    install_tailscale_binary
    ensure_user_bin_path
    stop_existing_user_tailscaled
    install_ts_command
    select_supervisor

    if [ "$SUPERVISOR_MODE" = "systemd" ]; then
        if [ ! -f "$SETUP_SERVICE_SCRIPT" ]; then
            error "Service setup script not found: $SETUP_SERVICE_SCRIPT"
            exit 1
        fi

        log "Setting up user-level tailscaled service..."
        if bash "$SETUP_SERVICE_SCRIPT"; then
            remove_cron_fallback_if_possible

            if [ ! -f "$SETUP_LOGROTATE_SCRIPT" ]; then
                error "Log rotation setup script not found: $SETUP_LOGROTATE_SCRIPT"
                exit 1
            fi

            log "Setting up user-level log rotation timer..."
            bash "$SETUP_LOGROTATE_SCRIPT"
        else
            warn "User-level systemd setup failed. Falling back to crontab + nohup."
            SUPERVISOR_MODE="cron"

            if [ ! -f "$SETUP_CRON_FALLBACK_SCRIPT" ]; then
                error "Cron fallback setup script not found: $SETUP_CRON_FALLBACK_SCRIPT"
                exit 1
            fi

            bash "$SETUP_CRON_FALLBACK_SCRIPT"
        fi
    else
        if [ ! -f "$SETUP_CRON_FALLBACK_SCRIPT" ]; then
            error "Cron fallback setup script not found: $SETUP_CRON_FALLBACK_SCRIPT"
            exit 1
        fi

        log "Setting up crontab + nohup fallback supervisor..."
        bash "$SETUP_CRON_FALLBACK_SCRIPT"
    fi

    wait_for_socket
    run_tailscale_up

    print_connection_info
}

main "$@"
