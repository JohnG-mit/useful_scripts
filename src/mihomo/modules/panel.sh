#!/usr/bin/env bash

mo_panel_url() {
    local base host port secret url
    base="$(mo_api_base)"
    host="${base#http://}"; port="${host##*:}"; host="${host%:*}"
    secret="$(mo_get_secret)"
    url="$base/ui/#/setup?hostname=$host&port=$port"
    [ -z "$secret" ] || url="$url&secret=$secret"
    printf '%s\n' "$url"
}

mo_panel_open_browser() {
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
    else return 1
    fi
}

mo_panel_open() {
    local print_only=false
    case "${1:-}" in --print-only|-p) print_only=true ;; esac
    mo_require_config || return
    [ -f "$MO_UI_DIR/index.html" ] || mo_warn "未找到面板文件：$MO_UI_DIR（可重新运行安装脚本以下载 zashboard）"
    local url controller
    url="$(mo_panel_url)"
    controller="$(mo_get_controller)"
    printf '本地面板 URL：%s\n' "$url"
    if [ -n "${SSH_CONNECTION:-}" ]; then
        printf '当前位于 SSH 会话。可在本地终端建立端口转发后访问：\n  ssh -N -L %s:%s %s@<服务器地址>\n' \
            "${controller##*:}" "$controller" "${USER:-$(id -un)}"
        return 0
    fi
    [ "$print_only" = true ] || mo_panel_open_browser "$url" || mo_warn "无法自动打开浏览器，请手动访问上述 URL"
}
