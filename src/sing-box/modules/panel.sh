#!/usr/bin/env bash

sb_panel_help() {
    cat <<'EOF'
用法：sb panel open [选项] [用户@主机]

选项：
  --local              强制打开本机面板
  --host 主机          远程 SSH 主机（IP、主机名或用户@主机）
  --local-port 端口    本地转发端口
  --print-only         只输出 URL，不打开浏览器
  --set-default 主机   保存默认远程主机
EOF
}

sb_panel_default_host() {
    [ -f "$SB_USER_CONFIG_FILE" ] || return 0
    sed -n 's/^SB_PANEL_DEFAULT_HOST=//p' "$SB_USER_CONFIG_FILE" | tail -n1
}

sb_panel_set_default_host() {
    local host="$1" temp
    mkdir -p "$SB_USER_CONFIG_DIR"
    temp="$(mktemp "${TMPDIR:-/tmp}/sb-config.XXXXXX")"
    if [ -f "$SB_USER_CONFIG_FILE" ]; then
        grep -v '^SB_PANEL_DEFAULT_HOST=' "$SB_USER_CONFIG_FILE" >"$temp" || true
    fi
    printf 'SB_PANEL_DEFAULT_HOST=%s\n' "$host" >>"$temp"
    install -m 600 "$temp" "$SB_USER_CONFIG_FILE"
    rm -f "$temp"
    sb_log "已保存默认面板主机：$host"
}

sb_panel_config_meta() {
    local config="$1"
    "$SB_PYTHON" - "$config" <<'PY' 2>/dev/null || printf '127.0.0.1|9090|ui|\n'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    api = json.load(f).get("experimental", {}).get("clash_api", {})
controller = api.get("external_controller", "127.0.0.1:9090")
host, _, port = controller.rpartition(":")
print("|".join((host or "127.0.0.1", port or "9090", api.get("external_ui") or "ui", api.get("secret") or "")))
PY
}

sb_panel_local_url() {
    local controller_host="$1" controller_port="$2" ui="$3" url_host
    case "$controller_host" in
        ''|0.0.0.0|'::'|'[::]'|'*') url_host='127.0.0.1' ;;
        '['*']') url_host="$controller_host" ;;
        *:*) url_host="[$controller_host]" ;;
        *) url_host="$controller_host" ;;
    esac
    printf 'http://%s:%s/%s\n' "$url_host" "$controller_port" "$ui"
}

sb_panel_open_browser() {
    local url="$1"
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
    elif command -v open >/dev/null 2>&1; then open "$url" >/dev/null 2>&1 &
    else return 1
    fi
}

sb_panel_open() {
    local host='' local_port='' local_mode=false print_only=false set_default='' meta controller_host controller_port ui secret url
    local default_host='' server_ip='' server_port='' server_target='' ssh_port_option=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --local) local_mode=true; shift ;;
            --host) [ "$#" -ge 2 ] || return 2; host="$2"; shift 2 ;;
            --local-port) [ "$#" -ge 2 ] || return 2; local_port="$2"; shift 2 ;;
            --print-only) print_only=true; shift ;;
            --set-default) [ "$#" -ge 2 ] || return 2; set_default="$2"; shift 2 ;;
            -h|--help) sb_panel_help; return ;;
            *) [ -z "$host" ] || { sb_error "未知面板选项：$1"; return 2; }; host="$1"; shift ;;
        esac
    done
    if [ "$local_mode" = true ] && { [ -n "$host" ] || [ -n "$set_default" ]; }; then
        sb_error "--local 不能与远程主机选项同时使用"
        return 2
    fi
    if [ -n "$set_default" ]; then
        sb_panel_set_default_host "$set_default"
        [ -n "$host" ] || return 0
    fi

    default_host="$(sb_panel_default_host)"
    if [ "$local_mode" = false ] && [ -z "$host" ] && [ -z "$default_host" ] && [ -n "${SSH_CONNECTION:-}" ]; then
        sb_require_config && sb_select_python || return
        meta="$(sb_panel_config_meta "$SB_CONFIG_FILE")"
        IFS='|' read -r controller_host controller_port ui secret <<<"$meta"
        local_port="${local_port:-$controller_port}"
        read -r _ _ server_ip server_port <<<"$SSH_CONNECTION"
        server_ip="${server_ip:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)}"
        server_target="${USER:-$(id -un)}@${server_ip:-<服务器IP或主机名>}"
        [ -z "$server_port" ] || [ "$server_port" = 22 ] || ssh_port_option=" -p $server_port"
        url="http://127.0.0.1:${local_port}/${ui}"
        printf '检测到当前位于 SSH 远程会话，面板未直接暴露到网络。\n'
        printf '请在本地计算机新开终端并执行：\n'
        printf '  ssh%s -N -L %s:%s:%s %s\n' "$ssh_port_option" "$local_port" "$controller_host" "$controller_port" "$server_target"
        printf '隧道建立后，在本地浏览器访问：\n  %s\n' "$url"
        printf 'SSH 目标可使用服务器 IP，也可替换为本地能够解析的主机名。\n'
        [ -z "$secret" ] || sb_warn "Clash API 需要密钥"
        return 0
    fi

    if [ "$local_mode" = false ]; then
        [ -n "$host" ] || host="$default_host"
    fi
    if [ -z "$host" ]; then
        sb_require_config && sb_select_python || return
        meta="$(sb_panel_config_meta "$SB_CONFIG_FILE")"
        IFS='|' read -r controller_host controller_port ui secret <<<"$meta"
        url="$(sb_panel_local_url "$controller_host" "$controller_port" "$ui")"
        printf '本地面板 URL：%s\n' "$url"
        [ -z "$secret" ] || sb_warn "Clash API 需要密钥"
        [ "$print_only" = true ] || sb_panel_open_browser "$url" || sb_warn "无法自动打开浏览器，请手动访问上述 URL"
        return 0
    fi

    sb_require_command ssh && sb_select_python || return
    meta="$(ssh -o ConnectTimeout=8 "$host" 'cat "$HOME/service/sing-box/config.json"' 2>/dev/null | "$SB_PYTHON" -c 'import json,sys; a=json.load(sys.stdin).get("experimental",{}).get("clash_api",{}); c=a.get("external_controller","127.0.0.1:9090"); h,_,p=c.rpartition(":"); print("|".join((h or "127.0.0.1",p or "9090",a.get("external_ui") or "ui",a.get("secret") or "")))' 2>/dev/null || printf '127.0.0.1|9090|ui|')"
    IFS='|' read -r controller_host controller_port ui secret <<<"$meta"
    if [ -n "$local_port" ]; then
        [[ "$local_port" =~ ^[0-9]+$ ]] && [ "$local_port" -le 65535 ] || { sb_error "无效的本地端口：$local_port"; return 2; }
        sb_port_in_use "$local_port" && { sb_error "本地端口已被占用：$local_port"; return 1; }
    else
        local_port="$(sb_find_available_port "$controller_port")"
    fi
    ssh -o ExitOnForwardFailure=yes -fN -L "127.0.0.1:$local_port:$controller_host:$controller_port" "$host" || return
    url="http://127.0.0.1:$local_port/$ui"
    printf '本地面板 URL：%s\n' "$url"
    [ -z "$secret" ] || sb_warn "远程 Clash API 需要密钥"
    [ "$print_only" = true ] || sb_panel_open_browser "$url" || sb_warn "无法自动打开浏览器，请手动访问上述 URL"
}
