#!/usr/bin/env bash

# Remove the marker block (and legacy disabled-line prefix) from one rc file.
mo_uninstall_rc_file() {
    local rc="$1" restore="$2" temp
    [ -f "$rc" ] || return 0
    grep -qF "$MO_RC_BEGIN" "$rc" || grep -qF "$MO_RC_DISABLED_PREFIX" "$rc" || return 0
    temp="$(mktemp)"
    awk -v begin="$MO_RC_BEGIN" -v end="$MO_RC_END" -v prefix="$MO_RC_DISABLED_PREFIX" -v restore="$restore" '
        $0 == begin { skipping = 1; next }
        skipping && $0 == end { skipping = 0; next }
        skipping { next }
        restore == "1" && index($0, prefix) == 1 { print substr($0, length(prefix) + 1); next }
        { print }
    ' "$rc" >"$temp"
    cp -p "$rc" "$rc.mihomo-uninstall.bak"
    cat "$temp" >"$rc"
    rm -f "$temp"
    mo_log "已清理 $rc（备份：$rc.mihomo-uninstall.bak）"
}

mo_uninstall() {
    mo_warn "即将卸载 mihomo 服务、mo 命令及相关配置。"
    mo_confirm "确认卸载？" N || { mo_log "已取消"; return 0; }

    local restore_singbox=0 remove_workdir=0
    if [ -f "$MO_SYSTEMD_DIR/sing-box.service" ] || grep -qF "$MO_RC_DISABLED_PREFIX" "$HOME/.zshrc" "$HOME/.bashrc" 2>/dev/null; then
        mo_confirm "是否恢复 sing-box 的服务与 Shell 配置？" Y && restore_singbox=1
    fi
    mo_confirm "是否同时删除工作目录（订阅、配置、日志缓存）：$MO_WORK_DIR？" N && remove_workdir=1

    if command -v systemctl >/dev/null 2>&1; then
        mo_ensure_user_systemd_env
        systemctl --user disable --now mihomo-sync.timer 2>/dev/null || true
        systemctl --user disable --now mihomo.service 2>/dev/null || true
        rm -f "$MO_SYSTEMD_DIR/mihomo.service" "$MO_SYSTEMD_DIR/mihomo-sync.service" "$MO_SYSTEMD_DIR/mihomo-sync.timer"
        systemctl --user daemon-reload 2>/dev/null || true
        systemctl --user reset-failed mihomo.service 2>/dev/null || true
    fi

    if declare -F mo_desktop_proxy_disable >/dev/null 2>&1 && command -v gsettings >/dev/null 2>&1; then
        mo_desktop_proxy_disable 2>/dev/null || true
    fi
    if declare -F mo_apt_proxy_disable >/dev/null 2>&1; then
        mo_apt_proxy_disable || true
    fi

    local rc
    for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.profile"; do
        mo_uninstall_rc_file "$rc" "$restore_singbox"
    done

    if [ "$restore_singbox" = 1 ] && [ -f "$MO_SYSTEMD_DIR/sing-box.service" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl --user enable --now sing-box.service 2>/dev/null || mo_warn "未能自动启动 sing-box，请手动执行：sb service restart"
        systemctl --user enable --now sing-box-log-rotate.timer 2>/dev/null || true
        mo_log "已恢复 sing-box 服务"
        if [ -x "$MO_BIN_DIR/sb" ] && command -v gsettings >/dev/null 2>&1; then
            "$MO_BIN_DIR/sb" desktop-proxy enable 2>/dev/null || true
        fi
    fi

    [ "$remove_workdir" = 0 ] || { rm -rf "$MO_WORK_DIR"; mo_log "已删除工作目录：$MO_WORK_DIR"; }
    rm -f "$MO_BINARY" "$MO_BINARY.old" "$MO_BIN_DIR/mo"
    rm -rf "$MO_RUNTIME_BASE" "$MO_USER_CONFIG_DIR"
    mo_log "mihomo 已卸载。请重新打开终端使 Shell 配置生效。"
}
