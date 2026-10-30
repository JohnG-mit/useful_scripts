#!/usr/bin/env bash

if [ -n "${MO_CORE_LOADED:-}" ]; then
    return 0
fi
MO_CORE_LOADED=1

MO_SERVICE_NAME="mihomo"
MO_BIN_DIR="${MO_BIN_DIR:-$HOME/.local/bin}"
MO_RUNTIME_BASE="${MO_RUNTIME_BASE:-$HOME/.local/lib/mihomo}"
MO_WORK_DIR="${MO_WORK_DIR:-$HOME/service/mihomo}"
MO_CONFIG_FILE="${MO_CONFIG_FILE:-$MO_WORK_DIR/config.yaml}"
MO_OVERRIDE_FILE="${MO_OVERRIDE_FILE:-$MO_WORK_DIR/override.yaml}"
MO_SOURCE_FILE="$MO_WORK_DIR/subscription.source"
MO_RAW_FILE="$MO_WORK_DIR/subscription.raw"
MO_PROVIDER_FILE="$MO_WORK_DIR/providers/sub.txt"
MO_UI_DIR="${MO_UI_DIR:-$MO_WORK_DIR/ui}"
MO_SYSTEMD_DIR="${MO_SYSTEMD_DIR:-$HOME/.config/systemd/user}"
MO_SERVICE_FILE="$MO_SYSTEMD_DIR/mihomo.service"
MO_SYNC_TIMER_FILE="$MO_SYSTEMD_DIR/mihomo-sync.timer"
MO_USER_CONFIG_DIR="${MO_USER_CONFIG_DIR:-$HOME/.config/mo}"
MO_USER_CONFIG_FILE="$MO_USER_CONFIG_DIR/config"
MO_BINARY="${MO_BINARY:-$MO_BIN_DIR/mihomo}"
MO_GH_PROXY="${MO_GH_PROXY-https://cdn.gh-proxy.org/}"
MO_RC_BEGIN='# >>> mihomo >>>'
MO_RC_END='# <<< mihomo <<<'
MO_RC_DISABLED_PREFIX='# [mihomo-installer disabled] '
MO_DEFAULT_MIXED_PORT=7897
MO_DEFAULT_API_PORT=9090

# Persisted installer choices (e.g. MO_PYTHON) so systemd jobs behave like a login shell.
if [ -r "$MO_USER_CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$MO_USER_CONFIG_FILE"
fi
MO_PYTHON="${MO_PYTHON:-python3}"

MO_GREEN='\033[0;32m'
MO_YELLOW='\033[1;33m'
MO_RED='\033[0;31m'
MO_NC='\033[0m'

mo_log() { printf '%b[INFO]%b %s\n' "$MO_GREEN" "$MO_NC" "$*"; }
mo_warn() { printf '%b[WARN]%b %s\n' "$MO_YELLOW" "$MO_NC" "$*" >&2; }
mo_error() { printf '%b[ERROR]%b %s\n' "$MO_RED" "$MO_NC" "$*" >&2; }

mo_require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        mo_error "缺少命令：$1"
        return 1
    }
}

mo_ensure_user_systemd_env() {
    local runtime_dir bus_path
    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "$runtime_dir" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
    fi
    bus_path="${XDG_RUNTIME_DIR:-$runtime_dir}/bus"
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "$bus_path" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=$bus_path"
    fi
}

mo_require_config() {
    [ -f "$MO_CONFIG_FILE" ] || {
        mo_error "未找到配置文件：$MO_CONFIG_FILE（请先执行 mo sub 导入订阅）"
        return 1
    }
}

mo_require_binary() {
    [ -x "$MO_BINARY" ] || {
        mo_error "未找到 mihomo 二进制文件：$MO_BINARY"
        return 1
    }
}

# Pick a python3 that has PyYAML; fall back to any python3 (enough for read-only helpers).
mo_select_python() {
    local candidate
    if [ -n "${MO_PYTHON:-}" ] && [ "$MO_PYTHON" != python3 ] && "$MO_PYTHON" -c 'import yaml' >/dev/null 2>&1; then
        return 0
    fi
    for candidate in python3 /usr/bin/python3; do
        if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import yaml' >/dev/null 2>&1; then
            MO_PYTHON="$candidate"
            export MO_PYTHON
            return 0
        fi
    done
    mo_error "需要带 PyYAML 的 Python 3（可执行：sudo apt install python3-yaml）"
    return 1
}

# Plain python3 is enough for modules that only use the standard library.
mo_select_python_basic() {
    command -v "$MO_PYTHON" >/dev/null 2>&1 && return 0
    command -v python3 >/dev/null 2>&1 && { MO_PYTHON=python3; return 0; }
    mo_error "需要 Python 3"
    return 1
}

mo_trim() {
    printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# Read a top-level scalar key from the generated config.yaml (no python needed).
mo_conf_get() {
    local key="$1" file="${2:-$MO_CONFIG_FILE}"
    [ -f "$file" ] || return 1
    awk -v key="$key" '
        index($0, key ":") == 1 {
            value = substr($0, length(key) + 2)
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+#.*$/, "", value)
            sub(/[[:space:]]+$/, "", value)
            if (value ~ /^".*"$/ || value ~ /^'\''.*'\''$/) value = substr(value, 2, length(value) - 2)
            print value
            exit
        }' "$file"
}

mo_get_mixed_port() {
    local port
    port="$(mo_conf_get mixed-port 2>/dev/null || true)"
    [[ "$port" =~ ^[0-9]+$ ]] || port="$(mo_conf_get mixed-port "$MO_OVERRIDE_FILE" 2>/dev/null || true)"
    [[ "$port" =~ ^[0-9]+$ ]] || port="$MO_DEFAULT_MIXED_PORT"
    printf '%s\n' "$port"
}

mo_get_controller() {
    local value
    value="$(mo_conf_get external-controller 2>/dev/null || true)"
    printf '%s\n' "${value:-127.0.0.1:$MO_DEFAULT_API_PORT}"
}

mo_get_secret() {
    mo_conf_get secret 2>/dev/null || true
}

# Base URL for the REST API, always reachable on loopback.
mo_api_base() {
    local controller host port
    controller="$(mo_get_controller)"
    host="${controller%:*}"; port="${controller##*:}"
    case "$host" in ''|0.0.0.0|'::'|'[::]'|'*') host=127.0.0.1 ;; esac
    printf 'http://%s:%s\n' "$host" "$port"
}

mo_set_proxy_env() {
    local port
    port="$(mo_get_mixed_port)"
    export http_proxy="http://127.0.0.1:$port"
    export https_proxy="$http_proxy" HTTP_PROXY="$http_proxy" HTTPS_PROXY="$http_proxy"
    export all_proxy="socks5h://127.0.0.1:$port" ALL_PROXY="$all_proxy"
}

mo_port_in_use() {
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

mo_find_available_port() {
    local port="$1"
    while mo_port_in_use "$port"; do port=$((port + 1)); done
    printf '%s\n' "$port"
}

mo_make_temp_dir() {
    mktemp -d "${TMPDIR:-/tmp}/mihomo.XXXXXX"
}

# Run python helper package bundled with the runtime.
mo_pyconfig() {
    PYTHONPATH="$MO_RUNTIME_DIR/python${PYTHONPATH:+:$PYTHONPATH}" "$MO_PYTHON" -m mihomo_config "$@"
}

mo_confirm() {
    local prompt="$1" default="${2:-Y}" answer
    [ -t 0 ] || { [ "$default" = Y ]; return; }
    if [ "$default" = Y ]; then printf '%s [Y/n] ' "$prompt"; else printf '%s [y/N] ' "$prompt"; fi
    IFS= read -r answer || answer=''
    case "$answer" in
        '') [ "$default" = Y ] ;;
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}
