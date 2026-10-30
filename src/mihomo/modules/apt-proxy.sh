#!/usr/bin/env bash

MO_APT_PROXY_CONFIG="${MO_APT_PROXY_CONFIG:-/etc/apt/apt.conf.d/99mihomo-proxy}"
MO_APT_PROXY_MARKER='// Managed by the mihomo installer.'
MO_APT_LEGACY_CONFIG="${MO_APT_LEGACY_CONFIG:-/etc/apt/apt.conf.d/99sing-box-proxy}"
MO_APT_LEGACY_MARKER='// Managed by the sing-box installer.'

# Run a command as root only when the target is not writable.
mo_apt_proxy_privileged() {
    local target="$1"; shift
    local parent
    parent="$(dirname "$target")"
    if [ -w "$parent" ] || { [ -e "$target" ] && [ -w "$target" ]; }; then
        "$@"
        return
    fi
    mo_require_command sudo || return
    sudo "$@"
}

mo_apt_proxy_install_file() {
    local source="$1" target="$2" parent
    parent="$(dirname "$target")"
    [ -d "$parent" ] || {
        mo_warn "APT 配置目录不存在：$parent"
        return 1
    }
    mo_apt_proxy_privileged "$target" install -m 644 "$source" "$target"
}

# The sing-box installer's APT proxy points at a port that no longer listens once it is replaced.
mo_apt_proxy_remove_legacy() {
    [ -e "$MO_APT_LEGACY_CONFIG" ] || return 0
    grep -Fqx "$MO_APT_LEGACY_MARKER" "$MO_APT_LEGACY_CONFIG" 2>/dev/null || return 0
    mo_apt_proxy_privileged "$MO_APT_LEGACY_CONFIG" rm -f "$MO_APT_LEGACY_CONFIG" &&
        mo_log "已移除旧的 sing-box APT 代理配置：$MO_APT_LEGACY_CONFIG"
}

mo_apt_proxy_enable() {
    mo_require_config || return
    local port temp
    port="$(mo_get_mixed_port)"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        mo_error "无效的 mixed 代理端口：$port"
        return 1
    }
    if [ -e "$MO_APT_PROXY_CONFIG" ] && ! grep -Fqx "$MO_APT_PROXY_MARKER" "$MO_APT_PROXY_CONFIG" 2>/dev/null; then
        mo_warn "APT 代理配置已存在且并非由 mihomo 管理：$MO_APT_PROXY_CONFIG"
        return 1
    fi
    temp="$(mktemp "${TMPDIR:-/tmp}/mihomo-apt-proxy.XXXXXX")"
    {
        printf '%s\n' "$MO_APT_PROXY_MARKER"
        printf 'Acquire::http::Proxy "http://127.0.0.1:%s/";\n' "$port"
        printf 'Acquire::https::Proxy "http://127.0.0.1:%s/";\n' "$port"
    } >"$temp"
    if ! mo_apt_proxy_install_file "$temp" "$MO_APT_PROXY_CONFIG"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp"
    mo_apt_proxy_remove_legacy || true
    mo_log "APT 代理已启用：127.0.0.1:$port（$MO_APT_PROXY_CONFIG）"
}

mo_apt_proxy_disable() {
    [ -e "$MO_APT_PROXY_CONFIG" ] || { mo_log "APT 代理未启用"; return 0; }
    grep -Fqx "$MO_APT_PROXY_MARKER" "$MO_APT_PROXY_CONFIG" 2>/dev/null || {
        mo_warn "$MO_APT_PROXY_CONFIG 并非由 mihomo 管理，未删除"
        return 1
    }
    mo_apt_proxy_privileged "$MO_APT_PROXY_CONFIG" rm -f "$MO_APT_PROXY_CONFIG" || return
    mo_log "APT 代理已禁用"
}

mo_apt_proxy_status() {
    if [ -e "$MO_APT_PROXY_CONFIG" ] && grep -Fqx "$MO_APT_PROXY_MARKER" "$MO_APT_PROXY_CONFIG" 2>/dev/null; then
        printf 'APT 代理：已启用（%s）\n' "$MO_APT_PROXY_CONFIG"
        grep -v '^//' "$MO_APT_PROXY_CONFIG"
    else
        printf 'APT 代理：未启用\n'
    fi
}
