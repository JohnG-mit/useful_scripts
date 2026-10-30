#!/usr/bin/env bash
# Terminal proxy helpers for the mihomo service. Source this file (bash or zsh).
#   vpn_on   set proxy variables for the current shell
#   vpn_off  unset them
#   vpn_s    show the current proxy status (alias: vpn_status)

_mo_vpn_port() {
    local config="${MO_CONFIG_FILE:-$HOME/service/mihomo/config.yaml}" port=''
    if [ -r "$config" ]; then
        port="$(awk '/^mixed-port:/ { gsub(/["\047[:space:]]/, "", $2); print $2; exit }' "$config" 2>/dev/null)"
    fi
    case "$port" in
        ''|*[!0-9]*) port=7897 ;;
    esac
    printf '%s\n' "$port"
}

_mo_vpn_service_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl --user is-active --quiet mihomo.service 2>/dev/null
}

vpn_on() {
    local port http socks
    port="$(_mo_vpn_port)"
    http="http://127.0.0.1:$port"
    socks="socks5://127.0.0.1:$port"
    export http_proxy="$http" https_proxy="$http" HTTP_PROXY="$http" HTTPS_PROXY="$http"
    export all_proxy="$socks" ALL_PROXY="$socks"
    export no_proxy="localhost,127.0.0.1,::1,172.18.0.0/16,192.168.0.0/16,10.0.0.0/8"
    export NO_PROXY="$no_proxy"
    printf '代理已启用：127.0.0.1:%s\n' "$port"
    _mo_vpn_service_active || printf '提示：mihomo 服务当前未运行（mo s 查看，mo r 重启）\n' >&2
    return 0
}

vpn_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    printf '代理已禁用\n'
}

vpn_s() {
    if [ -n "${http_proxy:-}" ]; then
        printf '终端代理：已启用\nhttp_proxy:  %s\nhttps_proxy: %s\nall_proxy:   %s\nno_proxy:    %s\n' \
            "$http_proxy" "${https_proxy:-}" "${all_proxy:-}" "${no_proxy:-}"
    else
        printf '终端代理：未启用\n'
    fi
    if _mo_vpn_service_active; then
        printf 'mihomo 服务：运行中（混合端口 %s）\n' "$(_mo_vpn_port)"
    else
        printf 'mihomo 服务：未运行\n'
    fi
}

vpn_status() { vpn_s "$@"; }

# Called from the rc file block: enable the proxy in new terminals when mihomo is running.
_mo_vpn_autostart() {
    _mo_vpn_service_active && vpn_on >/dev/null 2>&1
    return 0
}
