#!/bin/bash

set -e

SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
BIN_PATH="$INSTALL_DIR/sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"
CONFIG_FILE="$WORK_DIR/config.json"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME.service"
SB_CONFIG_DIR="$HOME/.config/sb"
SB_CONFIG_FILE="$SB_CONFIG_DIR/config"

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
用法: sb [命令]

无参数时进入交互菜单。

命令:
    s, status       查看用户级 sing-box 服务状态
    v, version      查看 sing-box 内核版本
    r, restart      重启用户级 sing-box 服务
    upgrade         更新 sing-box 内核（自动使用当前代理端口）
    self-update     一键更新 sb 脚本到最新版本
    d, dir          打印当前 sing-box 工作目录
    ip              输出当前默认代理出口 IP 和地区信息
    speedtest       测试当前默认代理速度
    p, proxy        打印当前可用代理并支持切换
    panel, tunnel   一键本地打开远端 clash 面板（SSH 转发）
    h, help         显示帮助
EOF
}

show_panel_help() {
    cat <<EOF
用法: sb panel [选项] [user@host]

选项:
    --host HOST               指定远端主机（例如 user@server）
    --local-port PORT         指定本地转发端口
    --print-only              仅打印本地访问地址，不自动打开浏览器
    --set-default HOST        保存默认远端主机
    -h, --help                显示此帮助信息

示例:
    sb panel                     # 仅在 SSH 会话中打开当前机器面板
    sb panel user@server
    sb panel --host user@server --local-port 19090
    sb panel --set-default user@server
    sb panel --print-only
EOF
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "Missing command: $cmd"
        exit 1
    fi
}

require_service_file() {
    if [ ! -f "$SERVICE_FILE" ]; then
        error "User service file not found: $SERVICE_FILE"
        error "Please run: bash src/sing-box/install.sh"
        exit 1
    fi
}

require_singbox_binary() {
    if [ ! -x "$BIN_PATH" ]; then
        error "sing-box binary not found: $BIN_PATH"
        error "Please run: bash src/sing-box/install.sh"
        exit 1
    fi
}

require_service_running() {
    require_service_file
    if ! systemctl --user is-active --quiet "$SERVICE_NAME"; then
        error "sing-box service is not running."
        error "Please run: systemctl --user restart $SERVICE_NAME"
        exit 1
    fi
}

require_config_file() {
    if [ ! -f "$CONFIG_FILE" ]; then
        error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
}

get_mixed_port() {
    if [ ! -f "$CONFIG_FILE" ] || ! command -v python3 >/dev/null 2>&1; then
        echo "7897"
        return
    fi

    python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "7897"
import json
import sys

config_path = sys.argv[1]

try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    for inbound in data.get("inbounds", []):
        if inbound.get("type") == "mixed":
            port = inbound.get("listen_port")
            if isinstance(port, int) and port > 0:
                print(port)
                raise SystemExit(0)
except Exception:
    pass

print(7897)
PY
}

set_proxy_env() {
    local port
    port="$(get_mixed_port)"

    export http_proxy="http://127.0.0.1:${port}"
    export https_proxy="http://127.0.0.1:${port}"
    export HTTP_PROXY="http://127.0.0.1:${port}"
    export HTTPS_PROXY="http://127.0.0.1:${port}"
    export all_proxy="socks5h://127.0.0.1:${port}"
    export ALL_PROXY="socks5h://127.0.0.1:${port}"
}

is_port_in_use() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q .
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -E "[.:]$port[[:space:]]" >/dev/null
        return
    fi

    return 1
}

find_available_local_port() {
    local start_port="$1"
    local port="$start_port"

    while is_port_in_use "$port"; do
        port=$((port + 1))
    done

    echo "$port"
}

ensure_sb_config_dir() {
    mkdir -p "$SB_CONFIG_DIR"
}

get_default_panel_host() {
    if [ ! -f "$SB_CONFIG_FILE" ]; then
        return
    fi

    sed -n 's/^SB_PANEL_DEFAULT_HOST=//p' "$SB_CONFIG_FILE" | tail -n 1
}

set_default_panel_host() {
    local host="$1"

    ensure_sb_config_dir

    if [ -f "$SB_CONFIG_FILE" ] && grep -q '^SB_PANEL_DEFAULT_HOST=' "$SB_CONFIG_FILE"; then
        sed -i "s|^SB_PANEL_DEFAULT_HOST=.*$|SB_PANEL_DEFAULT_HOST=$host|" "$SB_CONFIG_FILE"
    else
        echo "SB_PANEL_DEFAULT_HOST=$host" >> "$SB_CONFIG_FILE"
    fi

    log "Default panel host saved: $host"
}

get_remote_clash_meta() {
    local remote_host="$1"
    local remote_config

    if ! remote_config="$(ssh -o ConnectTimeout=8 "$remote_host" 'cat "$HOME/service/sing-box/config.json"' 2>/dev/null)"; then
        warn "Failed to read remote config, fallback to 127.0.0.1:9090/ui"
        echo "127.0.0.1|9090|ui|"
        return 0
    fi

    if [ -z "$remote_config" ]; then
        warn "Remote config is empty, fallback to 127.0.0.1:9090/ui"
        echo "127.0.0.1|9090|ui|"
        return 0
    fi

    python3 - <<'PY' <<< "$remote_config"
import json
import sys

raw = sys.stdin.read()
host = "127.0.0.1"
port = 9090
ui = "ui"
secret = ""

try:
    data = json.loads(raw)
    clash = ((data.get("experimental") or {}).get("clash_api") or {})

    external = clash.get("external_controller")
    if isinstance(external, str) and ":" in external:
        h, p = external.rsplit(":", 1)
        if h.strip():
            host = h.strip()
        if p.isdigit() and int(p) > 0:
            port = int(p)

    ui_value = clash.get("external_ui")
    if isinstance(ui_value, str) and ui_value.strip():
        ui = ui_value.strip().strip("/")

    secret_value = clash.get("secret")
    if isinstance(secret_value, str):
        secret = secret_value
except Exception:
    pass

print(f"{host}|{port}|{ui}|{secret}")
PY
}

get_local_clash_meta() {
    if [ ! -f "$CONFIG_FILE" ]; then
        warn "Local config not found, fallback to 127.0.0.1:9090/ui"
        echo "127.0.0.1|9090|ui|"
        return 0
    fi

    python3 - "$CONFIG_FILE" <<'PY' 2>/dev/null || echo "127.0.0.1|9090|ui|"
import json
import sys

config_path = sys.argv[1]
host = "127.0.0.1"
port = 9090
ui = "ui"
secret = ""

try:
    with open(config_path, "r", encoding="utf-8") as f:
        data = json.load(f)

    clash = ((data.get("experimental") or {}).get("clash_api") or {})

    external = clash.get("external_controller")
    if isinstance(external, str) and ":" in external:
        h, p = external.rsplit(":", 1)
        if h.strip():
            host = h.strip()
        if p.isdigit() and int(p) > 0:
            port = int(p)

    ui_value = clash.get("external_ui")
    if isinstance(ui_value, str) and ui_value.strip():
        ui = ui_value.strip().strip("/")

    secret_value = clash.get("secret")
    if isinstance(secret_value, str):
        secret = secret_value
except Exception:
    pass

print(f"{host}|{port}|{ui}|{secret}")
PY
}

open_local_browser() {
    local url="$1"

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 &
        return 0
    fi

    if command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 &
        return 0
    fi

    return 1
}

print_ssh_forward_guidance() {
    local remote_port="$1"
    local suggested_local_port="$2"
    local ui_path="$3"
    local ssh_user ssh_server ssh_port

    ssh_user="${USER:-user}"
    ssh_server="$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)"
    ssh_port="22"

    if [ -n "${SSH_CONNECTION:-}" ]; then
        ssh_port="$(printf '%s' "$SSH_CONNECTION" | awk '{print $4}')"
        if [ -z "$ssh_port" ]; then
            ssh_port="22"
        fi
    fi

    if [ -z "$ssh_server" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        ssh_server="$(printf '%s' "$SSH_CONNECTION" | awk '{print $3}')"
    fi

    if [ -z "$ssh_server" ]; then
        ssh_server="server"
    fi

    if [ -z "$suggested_local_port" ]; then
        suggested_local_port="$remote_port"
    fi

    echo ""
    warn "Detected SSH session. The URL above is on remote localhost and cannot be opened directly on your local browser."
    echo "Please run the following command on your local machine:"
    if [ "$ssh_port" = "22" ]; then
        echo "ssh -N -L ${suggested_local_port}:127.0.0.1:${remote_port} ${ssh_user}@${ssh_server}"
    else
        echo "ssh -p ${ssh_port} -N -L ${suggested_local_port}:127.0.0.1:${remote_port} ${ssh_user}@${ssh_server}"
    fi
    if [ -z "$ui_path" ]; then
        ui_path="ui"
    fi
    echo "Then open: http://127.0.0.1:${suggested_local_port}/${ui_path}"
    warn "If local port ${suggested_local_port} is occupied, change it to another available local port."
}

open_local_panel() {
    local local_port="$1"
    local print_only="$2"

    local local_meta controller_host controller_port ui_path secret
    local_meta="$(get_local_clash_meta)"
    IFS='|' read -r controller_host controller_port ui_path secret <<< "$local_meta"

    if [ -z "$controller_host" ]; then
        controller_host="127.0.0.1"
    fi
    if ! [[ "$controller_port" =~ ^[0-9]+$ ]] || [ "$controller_port" -le 0 ]; then
        controller_port="9090"
    fi
    if [ -z "$ui_path" ]; then
        ui_path="ui"
    fi

    if [ -n "$local_port" ]; then
        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -le 0 ] || [ "$local_port" -gt 65535 ]; then
            error "Invalid local port: $local_port"
            return 1
        fi
    fi

    local panel_url="http://${controller_host}:${controller_port}/${ui_path}"
    echo "Panel URL: $panel_url"

    if [ -n "$secret" ]; then
        warn "clash_api secret is enabled. Ensure your panel UI is configured with that secret."
    fi

    if [ -n "${SSH_CONNECTION:-}" ]; then
        local suggested_port
        suggested_port="$local_port"
        if [ -z "$suggested_port" ]; then
            suggested_port="$controller_port"
        fi
        print_ssh_forward_guidance "$controller_port" "$suggested_port" "$ui_path"
        return 0
    fi

    if [ "$print_only" = "false" ]; then
        if open_local_browser "$panel_url"; then
            log "Browser opening requested"
        else
            warn "Failed to auto-open browser. Please open the URL manually."
        fi
    fi
}

self_update_sb() {
    require_command curl

    local update_url tmp_file backup
    update_url="https://raw.githubusercontent.com/JohnG-mit/useful_scripts/main/src/sing-box/sb.sh"
    tmp_file="$(mktemp)"

    log "Downloading latest sb script..."
    if ! curl -fsSL "$update_url" -o "$tmp_file"; then
        rm -f "$tmp_file"
        error "Failed to download sb script from remote repository"
        return 1
    fi

    if ! bash -n "$tmp_file"; then
        rm -f "$tmp_file"
        error "Downloaded sb script failed syntax check"
        return 1
    fi

    mkdir -p "$INSTALL_DIR"

    if [ -f "$BIN_PATH" ]; then
        backup="$BIN_PATH.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$BIN_PATH" "$backup"
        log "Backup created: $backup"
    fi

    install -m 755 "$tmp_file" "$BIN_PATH"
    rm -f "$tmp_file"

    log "sb updated successfully: $BIN_PATH"
    log "Run 'hash -r' if your shell still uses an old cached command path"
}

open_remote_panel() {
    local remote_host=""
    local local_port=""
    local print_only="false"
    local set_default=""
    local should_connect="true"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --host)
                remote_host="$2"
                shift 2
                ;;
            --local-port)
                local_port="$2"
                shift 2
                ;;
            --print-only)
                print_only="true"
                shift
                ;;
            --set-default)
                set_default="$2"
                shift 2
                ;;
            -h|--help)
                show_panel_help
                return 0
                ;;
            *)
                if [ -z "$remote_host" ]; then
                    remote_host="$1"
                    shift
                else
                    error "Unknown argument: $1"
                    show_panel_help
                    return 1
                fi
                ;;
        esac
    done

    if [ -n "$set_default" ]; then
        set_default_panel_host "$set_default"
        if [ -z "$remote_host" ]; then
            should_connect="false"
        fi
    fi

    if [ "$should_connect" = "false" ]; then
        return 0
    fi

    # Default behavior:
    # - in SSH session: open current-machine panel directly
    # - in non-SSH session: require host/default-host and use tunnel mode
    if [ -z "$remote_host" ]; then
        if [ -n "${SSH_CONNECTION:-}" ]; then
            open_local_panel "$local_port" "$print_only"
            return $?
        fi

        remote_host="$(get_default_panel_host)"
        if [ -z "$remote_host" ]; then
            error "Remote host is required in local terminal. Use: sb panel user@host or sb panel --set-default user@host"
            return 1
        fi
    fi

    require_command ssh
    require_command python3

    local remote_meta controller_host controller_port ui_path secret
    remote_meta="$(get_remote_clash_meta "$remote_host")"
    IFS='|' read -r controller_host controller_port ui_path secret <<< "$remote_meta"

    if [ -z "$controller_host" ]; then
        controller_host="127.0.0.1"
    fi
    if ! [[ "$controller_port" =~ ^[0-9]+$ ]] || [ "$controller_port" -le 0 ]; then
        controller_port="9090"
    fi
    if [ -z "$ui_path" ]; then
        ui_path="ui"
    fi

    if [ -n "$local_port" ]; then
        if ! [[ "$local_port" =~ ^[0-9]+$ ]] || [ "$local_port" -le 0 ] || [ "$local_port" -gt 65535 ]; then
            error "Invalid local port: $local_port"
            return 1
        fi
        if is_port_in_use "$local_port"; then
            error "Local port $local_port is already in use"
            return 1
        fi
    else
        local_port="$(find_available_local_port "$controller_port")"
    fi

    local tunnel_spec="127.0.0.1:${local_port}:${controller_host}:${controller_port}"
    log "Creating SSH tunnel: $remote_host ($tunnel_spec)"

    if ! ssh -o ExitOnForwardFailure=yes -fN -L "$tunnel_spec" "$remote_host"; then
        error "Failed to establish SSH tunnel"
        return 1
    fi

    local panel_url="http://127.0.0.1:${local_port}/${ui_path}"
    log "Tunnel established"
    echo "Panel URL: $panel_url"

    if [ -n "$secret" ]; then
        warn "clash_api secret is enabled on remote side. Ensure your panel UI is configured with that secret."
    fi

    if [ "$print_only" = "false" ]; then
        if open_local_browser "$panel_url"; then
            log "Browser opening requested"
        else
            warn "Failed to auto-open browser. Please open the URL manually."
        fi
    fi

    echo "Stop tunnel example: pkill -f '$tunnel_spec'"
}

show_status() {
    require_service_file

    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        log "$SERVICE_NAME is active"
    else
        warn "$SERVICE_NAME is not active"
    fi

    systemctl --user status "$SERVICE_NAME" --no-pager
}

show_version() {
    require_singbox_binary

    if "$BIN_PATH" version >/dev/null 2>&1; then
        "$BIN_PATH" version
        return
    fi

    if "$BIN_PATH" -version >/dev/null 2>&1; then
        "$BIN_PATH" -version
        return
    fi

    error "Failed to get sing-box version"
    exit 1
}

restart_service() {
    require_service_file

    log "Restarting $SERVICE_NAME..."
    systemctl --user restart "$SERVICE_NAME"
    sleep 1

    if systemctl --user is-active --quiet "$SERVICE_NAME"; then
        log "$SERVICE_NAME restarted successfully"
    else
        error "$SERVICE_NAME failed to start after restart"
        exit 1
    fi
}

show_workdir() {
    echo "$WORK_DIR"
}

show_proxy_ip() {
    require_service_running
    require_command curl
    require_command python3

    set_proxy_env

    local response
    response="$(curl -fsSL --max-time 15 "https://ipapi.co/json/" 2>/dev/null || true)"

    if [ -z "$response" ]; then
        response="$(curl -fsSL --max-time 15 "https://ipinfo.io/json" 2>/dev/null || true)"
    fi

    if [ -z "$response" ]; then
        error "Failed to fetch proxy IP info"
        exit 1
    fi

    IP_JSON="$response" python3 - <<'PY'
import json
import os

raw = os.environ.get("IP_JSON", "").strip()
if not raw:
    raise SystemExit(1)

data = json.loads(raw)
ip = data.get("ip") or data.get("query") or "unknown"
country = data.get("country_name") or data.get("country") or "unknown"
region = data.get("region") or data.get("regionName") or "unknown"
city = data.get("city") or "unknown"
org = data.get("org") or data.get("organization") or "unknown"

print(f"IP: {ip}")
print(f"Location: {country} / {region} / {city}")
print(f"Org: {org}")
PY
}

map_singbox_arch() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        x86_64|amd64)
            echo "amd64"
            ;;
        aarch64|arm64)
            echo "arm64"
            ;;
        armv7l)
            echo "armv7"
            ;;
        i386|i686)
            echo "386"
            ;;
        *)
            error "Unsupported architecture for sing-box upgrade: $arch"
            exit 1
            ;;
    esac
}

get_singbox_version_text() {
    if "$BIN_PATH" version >/dev/null 2>&1; then
        "$BIN_PATH" version
        return 0
    fi

    "$BIN_PATH" -version
}

extract_version_number() {
    local text="$1"
    printf '%s\n' "$text" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z]+)?' | head -n1 || true
}

upgrade_singbox() {
    require_singbox_binary
    require_service_running
    require_command python3
    require_command curl
    require_command tar

    local sb_arch
    sb_arch="$(map_singbox_arch)"

    set_proxy_env

    local tmp_dir release_json_file release_info latest_tag download_url parse_status
    tmp_dir="$(mktemp -d)"
    release_json_file="$tmp_dir/release.json"

    if ! curl -fsSL \
        -H "Accept: application/vnd.github+json" \
        -H "User-Agent: sb-upgrader" \
        -o "$release_json_file" \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest"; then
        error "Failed to fetch latest sing-box release metadata via curl"
        rm -rf "$tmp_dir"
        exit 1
    fi

    if release_info="$(python3 - "$sb_arch" "$release_json_file" <<'PY'
import json
import sys

arch = sys.argv[1]
json_path = sys.argv[2]

try:
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except FileNotFoundError:
    raise SystemExit(1)
except json.JSONDecodeError:
    raise SystemExit(2)

if isinstance(data, dict) and data.get("message"):
    # For example: API rate limit exceeded.
    raise SystemExit(3)

latest_tag = data.get("tag_name", "")
asset_url = ""

for asset in data.get("assets", []):
    name = asset.get("name", "")
    if f"linux-{arch}.tar.gz" in name:
        asset_url = asset.get("browser_download_url", "")
        break

if not latest_tag or not asset_url:
    raise SystemExit(4)

print(latest_tag)
print(asset_url)
PY
)"; then
        :
    else
        parse_status=$?
        if [ "$parse_status" -eq 2 ]; then
            error "GitHub release response is not valid JSON"
        elif [ "$parse_status" -eq 3 ]; then
            error "GitHub API returned an error (possibly rate limit exceeded)"
        else
            error "Failed to parse latest sing-box release info"
        fi
        rm -rf "$tmp_dir"
        exit 1
    fi

    latest_tag="$(printf '%s\n' "$release_info" | sed -n '1p')"
    download_url="$(printf '%s\n' "$release_info" | sed -n '2p')"

    local current_text current_ver latest_ver
    current_text="$(get_singbox_version_text 2>/dev/null || true)"
    current_ver="$(extract_version_number "$current_text")"
    latest_ver="${latest_tag#v}"

    if [ -n "$current_ver" ] && [ "$current_ver" = "$latest_ver" ]; then
        log "sing-box is already up-to-date: $current_ver"
        rm -rf "$tmp_dir"
        show_version
        return
    fi

    local archive extracted_dir new_bin backup
    archive="$tmp_dir/sing-box.tar.gz"

    log "Downloading latest sing-box from official release..."
    if ! curl -fsSL -o "$archive" "$download_url"; then
        rm -rf "$tmp_dir"
        error "Failed to download sing-box package"
        exit 1
    fi

    if ! tar -xzf "$archive" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        error "Failed to extract sing-box package"
        exit 1
    fi

    extracted_dir="$(tar -tf "$archive" | head -1 | cut -d'/' -f1)"
    new_bin="$tmp_dir/$extracted_dir/sing-box"

    if [ ! -f "$new_bin" ]; then
        rm -rf "$tmp_dir"
        error "Cannot find sing-box binary in archive"
        exit 1
    fi

    if [ -f "$BIN_PATH" ]; then
        backup="$BIN_PATH.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$BIN_PATH" "$backup"
        log "Backup created: $backup"
    fi

    install -m 755 "$new_bin" "$BIN_PATH.new"
    mv "$BIN_PATH.new" "$BIN_PATH"
    rm -rf "$tmp_dir"

    restart_service

    log "sing-box upgraded successfully"
    show_version
}

map_speedtest_arch() {
    local arch
    arch="$(uname -m)"

    case "$arch" in
        i386|i686)
            echo "i386"
            ;;
        x86_64|amd64)
            echo "x86_64"
            ;;
        armv6l)
            echo "armel"
            ;;
        armv7l|armhf)
            echo "armhf"
            ;;
        aarch64|arm64)
            echo "aarch64"
            ;;
        *)
            error "Unsupported architecture for speedtest package: $arch"
            exit 1
            ;;
    esac
}

ensure_speedtest_cli() {
    if command -v speedtest-cli >/dev/null 2>&1; then
        command -v speedtest-cli
        return
    fi

    require_command curl
    require_command tar

    local arch package_url tmp_dir archive speedtest_bin
    arch="$(map_speedtest_arch)"
    package_url="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${arch}.tgz"

    tmp_dir="$(mktemp -d)"
    archive="$tmp_dir/ookla-speedtest.tgz"

    log "speedtest-cli not found, downloading official Ookla package..." >&2
    if ! curl -fsSL -o "$archive" "$package_url"; then
        rm -rf "$tmp_dir"
        error "Failed to download package: $package_url"
        exit 1
    fi

    if ! tar -xzf "$archive" -C "$tmp_dir"; then
        rm -rf "$tmp_dir"
        error "Failed to extract speedtest package"
        exit 1
    fi

    speedtest_bin="$(find "$tmp_dir" -type f -name speedtest | head -n1)"
    if [ -z "$speedtest_bin" ] || [ ! -f "$speedtest_bin" ]; then
        rm -rf "$tmp_dir"
        error "speedtest binary not found in package"
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    install -m 755 "$speedtest_bin" "$INSTALL_DIR/speedtest"

    cat > "$INSTALL_DIR/speedtest-cli" <<'EOF'
#!/bin/bash
set -e
exec "$HOME/bin/speedtest" --accept-license --accept-gdpr "$@"
EOF
    chmod +x "$INSTALL_DIR/speedtest-cli"

    rm -rf "$tmp_dir"
    log "Installed speedtest and compatibility command: $INSTALL_DIR/speedtest-cli" >&2

    echo "$INSTALL_DIR/speedtest-cli"
}

run_speedtest() {
    require_service_running
    require_command python3

    set_proxy_env

    local speedtest_cmd json_output mode
    speedtest_cmd="$(ensure_speedtest_cli)"

    if json_output="$($speedtest_cmd --json 2>/dev/null)"; then
        mode="legacy"
    elif json_output="$($speedtest_cmd -f json 2>/dev/null)"; then
        mode="ookla"
    else
        error "speedtest failed"
        exit 1
    fi

    SPEEDTEST_JSON="$json_output" python3 - "$mode" <<'PY'
import json
import os
import sys

mode = sys.argv[1]
raw = os.environ.get("SPEEDTEST_JSON", "").strip()
if not raw:
    raise SystemExit(1)

data = json.loads(raw)

if mode == "legacy":
    ping = data.get("ping")
    down_bps = data.get("download") or 0
    up_bps = data.get("upload") or 0
    server = (data.get("server") or {}).get("sponsor") or "unknown"
else:
    ping = (data.get("ping") or {}).get("latency")
    down_bps = (data.get("download") or {}).get("bandwidth", 0) * 8
    up_bps = (data.get("upload") or {}).get("bandwidth", 0) * 8
    server = (data.get("server") or {}).get("name") or "unknown"

down_mbps = down_bps / 1_000_000
up_mbps = up_bps / 1_000_000

print(f"Server: {server}")
if ping is None:
    print("Ping: unknown")
else:
    print(f"Ping: {float(ping):.2f} ms")
print(f"Download: {down_mbps:.2f} Mbps")
print(f"Upload: {up_mbps:.2f} Mbps")
PY
}

list_proxy_candidates() {
    require_config_file
    require_command python3

    python3 - "$CONFIG_FILE" <<'PY'
import json
import sys

config_path = sys.argv[1]

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

proxy_selector = None
for outbound in data.get("outbounds", []):
    if outbound.get("type") == "selector" and outbound.get("tag") == "proxy":
        proxy_selector = outbound
        break

if proxy_selector is None:
    raise SystemExit(2)

raw = proxy_selector.get("outbounds")
if not isinstance(raw, list):
    raise SystemExit(3)

candidates = []
for item in raw:
    if isinstance(item, str) and item not in candidates:
        candidates.append(item)

if not candidates:
    raise SystemExit(4)

current = proxy_selector.get("default")
if not isinstance(current, str) or current not in candidates:
    current = candidates[0]

print(f"Current: {current}")
print("Available:")
for idx, tag in enumerate(candidates, start=1):
    marker = " (current)" if tag == current else ""
    print(f"  {idx}) {tag}{marker}")
PY
}

switch_proxy_candidate() {
    local target="$1"
    require_config_file
    require_command python3

    local selected_tag
    if selected_tag="$(python3 - "$CONFIG_FILE" "$target" <<'PY'
import json
import sys

config_path = sys.argv[1]
target = sys.argv[2].strip()

if not target:
    raise SystemExit(5)

with open(config_path, "r", encoding="utf-8") as f:
    data = json.load(f)

proxy_selector = None
for outbound in data.get("outbounds", []):
    if outbound.get("type") == "selector" and outbound.get("tag") == "proxy":
        proxy_selector = outbound
        break

if proxy_selector is None:
    raise SystemExit(2)

raw = proxy_selector.get("outbounds")
if not isinstance(raw, list):
    raise SystemExit(3)

candidates = []
for item in raw:
    if isinstance(item, str) and item not in candidates:
        candidates.append(item)

if not candidates:
    raise SystemExit(4)

selected = None
if target.isdigit():
    index = int(target)
    if 1 <= index <= len(candidates):
        selected = candidates[index - 1]
else:
    if target in candidates:
        selected = target

if selected is None:
    raise SystemExit(6)

proxy_selector["default"] = selected

with open(config_path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)

print(selected)
PY
)"; then
        :
    else
        case "$?" in
            2)
                error "Cannot find outbound selector with tag 'proxy' in config"
                ;;
            3)
                error "Invalid proxy selector format in config"
                ;;
            4)
                error "No proxy candidates found in selector 'proxy'"
                ;;
            5)
                error "Empty proxy selection"
                ;;
            6)
                error "Invalid selection: $target"
                ;;
            *)
                error "Failed to update proxy default"
                ;;
        esac
        exit 1
    fi

    restart_service
    log "Default proxy switched to: $selected_tag"
}

handle_proxy_command() {
    local action="${1:-}"

    case "$action" in
        ""|choose|select)
            list_proxy_candidates || {
                case "$?" in
                    2)
                        error "Cannot find outbound selector with tag 'proxy' in config"
                        ;;
                    3)
                        error "Invalid proxy selector format in config"
                        ;;
                    4)
                        error "No proxy candidates found in selector 'proxy'"
                        ;;
                    *)
                        error "Failed to list proxy candidates"
                        ;;
                esac
                exit 1
            }

            echo ""
            read -r -p "Input index or tag to switch (press Enter to cancel): " choice
            choice="$(printf '%s' "$choice" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -z "$choice" ]; then
                warn "Proxy switch canceled"
                return
            fi
            switch_proxy_candidate "$choice"
            ;;
        list|ls)
            list_proxy_candidates || {
                case "$?" in
                    2)
                        error "Cannot find outbound selector with tag 'proxy' in config"
                        ;;
                    3)
                        error "Invalid proxy selector format in config"
                        ;;
                    4)
                        error "No proxy candidates found in selector 'proxy'"
                        ;;
                    *)
                        error "Failed to list proxy candidates"
                        ;;
                esac
                exit 1
            }
            ;;
        *)
            switch_proxy_candidate "$action"
            ;;
    esac
}

show_menu() {
    cat <<'EOF'
========== sb menu ==========
1) 查看 sing-box 服务状态 (sb s)
2) 查看 sing-box 内核版本 (sb v)
3) 重启 sing-box 服务 (sb r)
4) 更新 sing-box 内核 (sb upgrade)
5) 一键更新 sb 脚本 (sb self-update)
6) 打印 sing-box 工作目录 (sb d)
7) 查看当前默认代理出口 IP (sb ip)
8) 测试当前默认代理速度 (sb speedtest)
9) 打印并切换可用代理 (sb proxy)
10) 一键本地打开远端 clash 面板 (sb panel)
0) 退出
=============================
EOF

    read -r -p "请选择 [0-10]: " choice
    case "$choice" in
        1) show_status ;;
        2) show_version ;;
        3) restart_service ;;
        4) upgrade_singbox ;;
        5) self_update_sb ;;
        6) show_workdir ;;
        7) show_proxy_ip ;;
        8) run_speedtest ;;
        9) handle_proxy_command ;;
        10)
            read -r -p "请输入远端主机 (user@host，可留空使用默认): " panel_host
            panel_host="$(printf '%s' "$panel_host" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            if [ -n "$panel_host" ]; then
                open_remote_panel "$panel_host"
            else
                open_remote_panel
            fi
            ;;
        0) exit 0 ;;
        *)
            error "无效选项: $choice"
            exit 1
            ;;
    esac
}

main() {
    case "${1:-}" in
        "")
            show_menu
            ;;
        s|status)
            show_status
            ;;
        v|version)
            show_version
            ;;
        r|restart)
            restart_service
            ;;
        upgrade)
            upgrade_singbox
            ;;
        self-update)
            self_update_sb
            ;;
        d|dir|workdir)
            show_workdir
            ;;
        ip)
            show_proxy_ip
            ;;
        speedtest)
            run_speedtest
            ;;
        p|proxy)
            handle_proxy_command "${2:-}"
            ;;
        panel|tunnel)
            shift
            open_remote_panel "$@"
            ;;
        h|help|-h|--help)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
