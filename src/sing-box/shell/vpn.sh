#!/usr/bin/env bash

_sb_vpn_port() {
    local config="${SB_CONFIG_FILE:-$HOME/service/sing-box/config.json}"
    if [ ! -f "$config" ] || ! command -v python3 >/dev/null 2>&1; then printf '7897\n'; return; fi
    python3 - "$config" <<'PY' 2>/dev/null || printf '7897\n'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f: data=json.load(f)
    for inbound in data.get("inbounds", []):
        if inbound.get("type") == "mixed" and isinstance(inbound.get("listen_port"), int):
            print(inbound["listen_port"]); raise SystemExit
except Exception: pass
print(7897)
PY
}

vpn_on() {
    local port http socks
    port="$(_sb_vpn_port)"; http="http://127.0.0.1:$port"; socks="socks5://127.0.0.1:$port"
    export http_proxy="$http" https_proxy="$http" HTTP_PROXY="$http" HTTPS_PROXY="$http"
    export all_proxy="$socks" ALL_PROXY="$socks"
    export no_proxy="localhost,127.0.0.1,172.18.0.0/16,192.168.0.0/16,10.0.0.0/8"
    export NO_PROXY="$no_proxy"
    printf '代理已启用：127.0.0.1:%s\n' "$port"
}

vpn_off() {
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    printf '代理已禁用\n'
}

vpn_status() {
    if [ -n "${http_proxy:-}" ]; then
        printf 'http_proxy: %s\nhttps_proxy: %s\nall_proxy: %s\nno_proxy: %s\n' \
            "$http_proxy" "${https_proxy:-}" "${all_proxy:-}" "${no_proxy:-}"
    else
        printf '当前 Shell 未配置代理\n'
    fi
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    printf '请 source 此文件，然后使用 vpn_on、vpn_off 或 vpn_status。\n' >&2
    exit 1
fi
