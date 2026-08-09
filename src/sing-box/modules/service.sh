#!/usr/bin/env bash

sb_service_require_unit() {
    [ -f "$SB_SERVICE_FILE" ] || {
        sb_error "未找到用户服务文件：$SB_SERVICE_FILE"
        return 1
    }
    sb_require_command systemctl
}

sb_service_require_running() {
    sb_service_require_unit && systemctl --user is-active --quiet "$SB_SERVICE_NAME" || {
        sb_error "sing-box 服务未运行"
        return 1
    }
}

sb_service_status() {
    sb_service_require_unit || return
    if systemctl --user is-active --quiet "$SB_SERVICE_NAME"; then
        sb_log "$SB_SERVICE_NAME 服务正在运行"
    else
        sb_warn "$SB_SERVICE_NAME 服务未运行"
    fi
    systemctl --user status "$SB_SERVICE_NAME" --no-pager
}

sb_service_restart() {
    sb_service_require_unit || return
    sb_log "正在重启 $SB_SERVICE_NAME..."
    systemctl --user restart "$SB_SERVICE_NAME"
    sleep 1
    systemctl --user is-active --quiet "$SB_SERVICE_NAME" || {
        sb_error "$SB_SERVICE_NAME 重启后启动失败"
        return 1
    }
    sb_log "$SB_SERVICE_NAME 重启成功"
}
