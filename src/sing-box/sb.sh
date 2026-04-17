#!/bin/bash

set -e

SERVICE_NAME="sing-box"
INSTALL_DIR="$HOME/bin"
BIN_PATH="$INSTALL_DIR/sing-box"
WORK_DIR="$HOME/service/$SERVICE_NAME"
CONFIG_FILE="$WORK_DIR/config.json"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME.service"

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
  d, dir          打印当前 sing-box 工作目录
  ip              输出当前默认代理出口 IP 和地区信息
  speedtest       测试当前默认代理速度
    p, proxy        打印当前可用代理并支持切换
  h, help         显示帮助
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
5) 打印 sing-box 工作目录 (sb d)
6) 查看当前默认代理出口 IP (sb ip)
7) 测试当前默认代理速度 (sb speedtest)
8) 打印并切换可用代理 (sb proxy)
0) 退出
=============================
EOF

    read -r -p "请选择 [0-8]: " choice
    case "$choice" in
        1) show_status ;;
        2) show_version ;;
        3) restart_service ;;
        4) upgrade_singbox ;;
        5) show_workdir ;;
        6) show_proxy_ip ;;
        7) run_speedtest ;;
        8) handle_proxy_command ;;
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
