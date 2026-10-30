#!/usr/bin/env bash

mo_core_version() {
    mo_require_binary || return
    "$MO_BINARY" -v 2>/dev/null | head -n1
    local latest
    latest="$(MO_VERSION='' mo_latest_version 2>/dev/null || true)"
    if [ -n "$latest" ]; then
        if [ "$latest" = "$(mo_current_version)" ]; then
            mo_log "已是最新版本：$latest"
        else
            mo_log "可升级到：$latest（执行 mo upgrade）"
        fi
    else
        mo_warn "无法获取最新版本信息"
    fi
}

mo_core_upgrade() {
    local force=false latest current
    [ "${1:-}" != --force ] || force=true
    latest="$(mo_latest_version)" || return
    current="$(mo_current_version 2>/dev/null || true)"
    if [ "$force" = false ] && [ -n "$current" ] && [ "$current" = "$latest" ]; then
        mo_log "当前已是最新版本：$current"
        return 0
    fi
    mo_log "mihomo ${current:-未安装} -> $latest"
    mo_artifact_install_core "$MO_BINARY" || return
    if declare -F mo_tun_reapply_cap >/dev/null 2>&1; then
        mo_tun_reapply_cap || true
    fi
    if [ -f "$MO_SERVICE_FILE" ]; then
        if ! mo_service_restart; then
            if [ -x "$MO_BINARY.old" ]; then
                mo_warn "新版本无法正常运行，正在回滚到 $current"
                mv -f "$MO_BINARY.old" "$MO_BINARY"
                if declare -F mo_tun_reapply_cap >/dev/null 2>&1; then
                    mo_tun_reapply_cap || true
                fi
                mo_service_restart || true
            fi
            return 1
        fi
    fi
    mo_log "mihomo 核心升级完成"
    "$MO_BINARY" -v 2>/dev/null | head -n1
}
