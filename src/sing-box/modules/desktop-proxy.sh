#!/usr/bin/env bash

SB_DESKTOP_PROXY_HOST="${SB_DESKTOP_PROXY_HOST:-127.0.0.1}"
SB_DESKTOP_PROXY_IGNORE_DEFAULTS=(
    localhost
    '*.local'
    '127.*'
    '::1'
    '10.*'
    '172.16.*'
    '172.17.*'
    '172.18.*'
    '172.19.*'
    '172.2*'
    '172.30.*'
    '172.31.*'
    '192.168.*'
)
SB_DESKTOP_PROXY_FORCE_PROXY_DEFAULTS=(
    'lightwheel.ai'
    '*.lightwheel.ai'
)

sb_desktop_proxy_prepare() {
    sb_require_command gsettings || return
    if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
        export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
    fi
    [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || {
        sb_warn "桌面会话总线不可用，将跳过 GNOME 代理配置"
        return 1
    }
    gsettings list-schemas | grep -Fxq org.gnome.system.proxy || {
        sb_warn "GNOME 系统代理设置不可用"
        return 1
    }
}

sb_desktop_proxy_ignore_hosts() {
    local current
    sb_select_python || return
    current="$(gsettings get org.gnome.system.proxy ignore-hosts 2>/dev/null || printf '@as []')"
    "$SB_PYTHON" - \
        "$current" \
        "${#SB_DESKTOP_PROXY_FORCE_PROXY_DEFAULTS[@]}" \
        "${SB_DESKTOP_PROXY_FORCE_PROXY_DEFAULTS[@]}" \
        "${SB_DESKTOP_PROXY_IGNORE_DEFAULTS[@]}" <<'PY'
import ast
import sys

raw = sys.argv[1].strip()
force_count = int(sys.argv[2])
force_proxy = set(sys.argv[3:3 + force_count])
defaults = sys.argv[3 + force_count:]
if raw.startswith("@as "):
    raw = raw[4:]
try:
    existing = ast.literal_eval(raw)
except (SyntaxError, ValueError):
    existing = []

merged = []
for host in [*existing, *defaults]:
    if isinstance(host, str) and host not in force_proxy and host not in merged:
        merged.append(host)
print(repr(merged))
PY
}

sb_desktop_proxy_enable() {
    sb_desktop_proxy_prepare || return
    sb_require_config || return
    local port ignore_hosts
    port="$(sb_get_mixed_port)"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -le 65535 ] || {
        sb_error "无效的 mixed 代理端口：$port"
        return 1
    }
    ignore_hosts="$(sb_desktop_proxy_ignore_hosts)" || return

    gsettings set org.gnome.system.proxy use-same-proxy false
    gsettings set org.gnome.system.proxy.http host "$SB_DESKTOP_PROXY_HOST"
    gsettings set org.gnome.system.proxy.http port "$port"
    gsettings set org.gnome.system.proxy.http use-authentication false
    gsettings set org.gnome.system.proxy.http enabled true
    gsettings set org.gnome.system.proxy.https host "$SB_DESKTOP_PROXY_HOST"
    gsettings set org.gnome.system.proxy.https port "$port"
    gsettings set org.gnome.system.proxy.socks host "$SB_DESKTOP_PROXY_HOST"
    gsettings set org.gnome.system.proxy.socks port "$port"
    gsettings set org.gnome.system.proxy ignore-hosts "$ignore_hosts"
    gsettings set org.gnome.system.proxy mode manual
    sb_log "GNOME 桌面代理已启用：$SB_DESKTOP_PROXY_HOST:$port"
}

sb_desktop_proxy_disable() {
    sb_desktop_proxy_prepare || return
    gsettings set org.gnome.system.proxy mode none
    sb_log "GNOME 桌面代理已禁用"
}

sb_desktop_proxy_status() {
    sb_desktop_proxy_prepare || return
    local mode
    mode="$(gsettings get org.gnome.system.proxy mode)"
    printf '模式：%s\n' "$mode"
    printf 'HTTP: %s:%s\n' \
        "$(gsettings get org.gnome.system.proxy.http host)" \
        "$(gsettings get org.gnome.system.proxy.http port)"
    printf 'HTTPS: %s:%s\n' \
        "$(gsettings get org.gnome.system.proxy.https host)" \
        "$(gsettings get org.gnome.system.proxy.https port)"
    printf 'SOCKS: %s:%s\n' \
        "$(gsettings get org.gnome.system.proxy.socks host)" \
        "$(gsettings get org.gnome.system.proxy.socks port)"
    printf '忽略的主机：%s\n' "$(gsettings get org.gnome.system.proxy ignore-hosts)"
}
