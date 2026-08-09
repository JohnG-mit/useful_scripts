#!/usr/bin/env bash

SB_APT_PROXY_CONFIG="${SB_APT_PROXY_CONFIG:-/etc/apt/apt.conf.d/99sing-box-proxy}"
SB_APT_PROXY_MARKER='// Managed by the sing-box installer.'

sb_apt_proxy_install_file() {
    local source="$1" target="$2" parent
    parent="$(dirname "$target")"
    [ -d "$parent" ] || {
        sb_warn "APT 配置目录不存在：$parent"
        return 1
    }
    if [ -w "$parent" ] || { [ -e "$target" ] && [ -w "$target" ]; }; then
        install -m 644 "$source" "$target"
        return
    fi
    sb_require_command sudo || return
    sudo install -m 644 "$source" "$target"
}

sb_apt_proxy_enable() {
    sb_require_config || return
    local port temp
    port="$(sb_get_mixed_port)"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
        sb_error "无效的 mixed 代理端口：$port"
        return 1
    }

    if [ -e "$SB_APT_PROXY_CONFIG" ] && ! grep -Fqx "$SB_APT_PROXY_MARKER" "$SB_APT_PROXY_CONFIG" 2>/dev/null; then
        sb_warn "APT 代理配置已存在且并非由 sing-box 管理：$SB_APT_PROXY_CONFIG"
        return 1
    fi

    temp="$(mktemp "${TMPDIR:-/tmp}/sing-box-apt-proxy.XXXXXX")"
    {
        printf '%s\n' "$SB_APT_PROXY_MARKER"
        printf 'Acquire::http::Proxy "http://127.0.0.1:%s/";\n' "$port"
        printf 'Acquire::https::Proxy "http://127.0.0.1:%s/";\n' "$port"
    } >"$temp"
    if ! sb_apt_proxy_install_file "$temp" "$SB_APT_PROXY_CONFIG"; then
        rm -f "$temp"
        return 1
    fi
    rm -f "$temp"
    sb_log "APT 代理已启用：127.0.0.1:$port（$SB_APT_PROXY_CONFIG）"
}
