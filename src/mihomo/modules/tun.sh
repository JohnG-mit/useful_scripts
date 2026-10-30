#!/usr/bin/env bash

MO_TUN_CAPS="cap_net_admin,cap_net_bind_service,cap_net_raw=+ep"

mo_tun_enabled() {
    mo_select_python >/dev/null 2>&1 || return 1
    [ "$(mo_pyconfig override-get "$MO_OVERRIDE_FILE" tun.enable 2>/dev/null || true)" = true ]
}

mo_tun_has_cap() {
    command -v getcap >/dev/null 2>&1 && getcap "$MO_BINARY" 2>/dev/null | grep -q cap_net_admin
}

# Grant the capabilities TUN needs; requires sudo once (and again after each binary replacement).
mo_tun_grant_cap() {
    mo_require_binary || return
    mo_tun_has_cap && return 0
    mo_require_command setcap || {
        mo_error "未找到 setcap（可执行：sudo apt install libcap2-bin）"
        return 1
    }
    mo_log "需要 sudo 为 $MO_BINARY 授予 TUN 所需权限"
    sudo setcap "$MO_TUN_CAPS" "$MO_BINARY"
}

# Called after the binary is replaced (mo upgrade): file capabilities do not survive.
mo_tun_reapply_cap() {
    mo_tun_enabled || return 0
    mo_tun_has_cap && return 0
    mo_tun_grant_cap
}

mo_tun_apply() {
    local value="$1"
    mo_select_python || return
    mo_pyconfig override-init "$MO_OVERRIDE_FILE" "$MO_RUNTIME_DIR/resources/override.yaml" || return
    mo_pyconfig override-set "$MO_OVERRIDE_FILE" "tun.enable=$value" || return
    mo_subscription_update --raw
}

mo_tun_on() {
    [ -e /dev/net/tun ] || { mo_error "未找到 /dev/net/tun，当前系统无法使用 TUN"; return 1; }
    mo_tun_grant_cap || return
    if ! mo_tun_apply true; then
        mo_warn "开启 TUN 失败，正在恢复为关闭状态"
        mo_tun_apply false || true
        return 1
    fi
    mo_log "TUN 已开启（透明代理；如异常可执行 mo tun off）"
}

mo_tun_off() {
    mo_tun_apply false || return
    mo_log "TUN 已关闭"
}

mo_tun_status() {
    if mo_tun_enabled; then
        printf 'TUN：已开启\n'
    else
        printf 'TUN：未开启\n'
    fi
    if mo_tun_has_cap; then
        printf '二进制权限：已授予 (%s)\n' "$(getcap "$MO_BINARY" 2>/dev/null | sed 's/^.*= *//')"
    else
        printf '二进制权限：未授予（mo tun on 时会通过 sudo setcap 授权）\n'
    fi
    [ -e /dev/net/tun ] && printf '/dev/net/tun：存在\n' || printf '/dev/net/tun：不存在\n'
}

mo_tun() {
    case "${1:-}" in
        on|enable) mo_tun_on ;;
        off|disable) mo_tun_off ;;
        status|'') mo_tun_status ;;
        *) mo_error "用法：mo tun on|off|status"; return 2 ;;
    esac
}
