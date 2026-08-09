#!/usr/bin/env bash

if [ -n "${SB_CORE_LOADED:-}" ]; then
    return 0
fi
SB_CORE_LOADED=1

SB_SERVICE_NAME="sing-box"
SB_BIN_DIR="${SB_BIN_DIR:-$HOME/.local/bin}"
SB_RUNTIME_BASE="${SB_RUNTIME_BASE:-$HOME/.local/lib/sing-box}"
SB_WORK_DIR="${SB_WORK_DIR:-$HOME/service/sing-box}"
SB_CONFIG_FILE="${SB_CONFIG_FILE:-$SB_WORK_DIR/config.json}"
SB_SYSTEMD_DIR="${SB_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
SB_SERVICE_FILE="$SB_SYSTEMD_DIR/sing-box.service"
SB_USER_CONFIG_DIR="${SB_USER_CONFIG_DIR:-$HOME/.config/sb}"
SB_USER_CONFIG_FILE="$SB_USER_CONFIG_DIR/config"
SB_BINARY="$SB_BIN_DIR/sing-box"
SB_CONFIG_TEMPLATE="${SB_CONFIG_TEMPLATE:-$SB_RUNTIME_DIR/resources/config-template.json}"
SB_ARTIFACT_LOCK="${SB_ARTIFACT_LOCK:-$SB_RUNTIME_DIR/resources/artifacts.lock}"
SB_PYTHON="${SB_PYTHON:-python3}"

SB_GREEN='\033[0;32m'
SB_YELLOW='\033[1;33m'
SB_RED='\033[0;31m'
SB_NC='\033[0m'

sb_log() { printf '%b[INFO]%b %s\n' "$SB_GREEN" "$SB_NC" "$*"; }
sb_warn() { printf '%b[WARN]%b %s\n' "$SB_YELLOW" "$SB_NC" "$*" >&2; }
sb_error() { printf '%b[ERROR]%b %s\n' "$SB_RED" "$SB_NC" "$*" >&2; }

sb_require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        sb_error "缺少命令：$1"
        return 1
    }
}

sb_require_config() {
    [ -f "$SB_CONFIG_FILE" ] || {
        sb_error "未找到配置文件：$SB_CONFIG_FILE"
        return 1
    }
}

sb_require_binary() {
    [ -x "$SB_BINARY" ] || {
        sb_error "未找到 sing-box 二进制文件：$SB_BINARY"
        return 1
    }
}

sb_select_python() {
    local candidate
    for candidate in python3 /bin/python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
            SB_PYTHON="$candidate"
            export SB_PYTHON
            return 0
        fi
    done
    for candidate in python3 /bin/python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'pass' >/dev/null 2>&1; then
            SB_PYTHON="$candidate"
            export SB_PYTHON
            return 0
        fi
    done
    sb_error "需要 Python 3"
    return 1
}

sb_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

sb_get_mixed_port() {
    if [ ! -f "$SB_CONFIG_FILE" ] || ! command -v python3 >/dev/null 2>&1; then
        printf '7897\n'
        return
    fi
    python3 - "$SB_CONFIG_FILE" <<'PY' 2>/dev/null || printf '7897\n'
import json
import sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        data = json.load(f)
    for inbound in data.get("inbounds", []):
        if inbound.get("type") == "mixed" and isinstance(inbound.get("listen_port"), int):
            print(inbound["listen_port"])
            raise SystemExit(0)
except Exception:
    pass
print(7897)
PY
}

sb_set_proxy_env() {
    local port
    port="$(sb_get_mixed_port)"
    export http_proxy="http://127.0.0.1:$port"
    export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
    export all_proxy="socks5h://127.0.0.1:$port" ALL_PROXY="$all_proxy"
}

sb_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn "sport = :$port" 2>/dev/null | tail -n +2 | grep -q .
    elif command -v lsof >/dev/null 2>&1; then
        lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v netstat >/dev/null 2>&1; then
        netstat -ltn 2>/dev/null | grep -E "[.:]$port[[:space:]]" >/dev/null
    else
        return 1
    fi
}

sb_find_available_port() {
    local port="$1"
    while sb_port_in_use "$port"; do port=$((port + 1)); done
    printf '%s\n' "$port"
}

sb_make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/sing-box.XXXXXX"
}
